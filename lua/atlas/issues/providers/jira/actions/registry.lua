local M = {}

local actions = require("atlas.issues.actions")
local icons = require("atlas.ui.shared.icons")
local statusline = require("atlas.ui.statusline")
local async_picker = require("atlas.ui.components.async_picker")
local issues_api = require("atlas.issues.providers.jira.api.issues")
local notify = require("atlas.core.notify")
local transitions_api = require("atlas.issues.providers.jira.api.transitions")
local users_api = require("atlas.issues.providers.jira.api.users")
local issues_state = require("atlas.issues.state")
local config = require("atlas.issues.providers.jira.api.config")

---@param ctx AtlasIssueActionContext
---@return boolean
local function has_issue_key(ctx)
	local issue = ctx.issue
	if type(issue) ~= "table" then
		return false
	end
	local key = tostring(issue.key or "")
	return key ~= ""
end

---@return string
local function current_jql()
	local view = issues_state.active_view or issues_state.current_view
	if type(view) ~= "table" then
		return ""
	end
	---@cast view AtlasJiraViewConfig
	return tostring(view.jql or "")
end

---@type AtlasIssueAction[]
local ACTIONS = {}
M.items = ACTIONS

---@param action AtlasIssueAction
local function register(action)
	table.insert(ACTIONS, action)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function transition_available(ctx)
	return has_issue_key(ctx)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function transition(ctx, done)
	local issue = assert(ctx.issue)

	local issue_key = issue.key
	local current_status = tostring(issue.status or "")
	local all_items = nil

	local status_category_icons = {
		new = icons.fallback(),
		indeterminate = icons.general("info"),
		done = icons.general("success"),
	}

	async_picker.open({
		title = string.format("Transition %s", issue_key),
		prompt = "Filter transitions",
		debounce_ms = 0,
		identifier = "jira_transitions:" .. issue_key,
		format_item = function(item)
			local transition = item.value
			local category = type(transition) == "table" and transition.to_status_category or nil
			local icon = (category and status_category_icons[category]) or icons.fallback()
			return string.format("%s %s", icon, item.label)
		end,
		fetch = function(fetch_ctx, fetch_done)
			if all_items then
				local query = vim.trim(fetch_ctx.query):lower()
				if query == "" then
					fetch_done(all_items, nil)
					return
				end
				local filtered = {}
				for _, item in ipairs(all_items) do
					if item.label:lower():find(query, 1, true) then
						table.insert(filtered, item)
					end
				end
				fetch_done(filtered, nil)
				return
			end

			transitions_api.get_transitions(issue_key, function(transitions, err)
				if err ~= nil or transitions == nil then
					fetch_done(nil, err or "Failed to load transitions")
					return
				end

				all_items = {}
				for _, transition in ipairs(transitions) do
					local to_status = tostring((transition and transition.to_status_name) or "")
					if current_status == "" or to_status == "" or to_status ~= current_status then
						table.insert(all_items, {
							id = tostring(transition.id or ""),
							label = tostring(transition.name or ""),
							value = transition,
						})
					end
				end
				fetch_done(all_items, nil)
			end)
		end,
		on_select = function(item)
			local selected = item.value
			statusline.notify("loading", string.format("Transitioning %s...", issue_key))
			transitions_api.transition_issue(issue_key, selected.id, function(ok, err)
				if not ok then
					statusline.notify("error", err or "Transition failed")
					done(nil, err or "Transition failed")
					return
				end

				statusline.notify(
					"success",
					string.format("Transitioned %s to %s", issue_key, selected.name or ""),
					1200
				)
				done({ issue_key = issue_key }, nil)
			end)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function assign_available(ctx)
	return has_issue_key(ctx)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function assign(ctx, done)
	local issue = assert(ctx.issue)

	local issue_key = issue.key
	local issue_project_key = issue.project and issue.project.key or nil
	local current_assignee_key = vim.trim(tostring(issue.assignee and issue.assignee.display_name or "")):lower()

	local function to_picker_items(users)
		local items = {}
		local current_user = issues_state.current_user
		local current_user_account_id = current_user and current_user.account_id or nil
		local current_user_item = nil
		local seen_current_user = false

		if current_assignee_key ~= "" and current_assignee_key ~= "unassigned" then
			table.insert(items, {
				id = "__unassign__",
				label = "Unassign",
				value = { account_id = nil, display_name = "Unassign" },
			})
		end

		for _, user in ipairs(users or {}) do
			local user_name = vim.trim(tostring(user.display_name or "")):lower()
			if user_name ~= current_assignee_key then
				local item = { id = user.account_id or "", label = user.display_name or "", value = user }
				if current_user_account_id and user.account_id == current_user_account_id then
					seen_current_user = true
					current_user_item = item
				else
					table.insert(items, item)
				end
			end
		end

		if current_user_account_id and current_user then
			if not seen_current_user then
				current_user_item = {
					id = current_user_account_id,
					label = current_user.display_name or "",
					value = current_user,
				}
			end
			if current_user_item then
				table.insert(items, 1, current_user_item)
			end
		end

		return items
	end

	async_picker.open({
		title = string.format("Assign %s", issue_key),
		prompt = "Search users",
		initial_items = to_picker_items({}),
		debounce_ms = 250,
		cache_ttl_ms = 60000,
		identifier = "jira_users:" .. (issue_project_key or ""),
		fetch_on_open = false,
		format_item = function(item)
			if item.id == "__unassign__" then
				return item.label
			end
			return string.format("%s %s", icons.general("user"), item.label)
		end,
		fetch = function(fetch_ctx, fetch_done)
			users_api.get_assignable_users(
				{ issue_key = issue_key, project = issue_project_key },
				fetch_ctx.query,
				function(users, err)
					if err then
						fetch_done(nil, err)
						return
					end
					fetch_done(to_picker_items(users), nil)
				end
			)
		end,
		on_select = function(item)
			local selected = item.value
			statusline.notify("loading", string.format("Assigning %s...", issue_key))
			users_api.assign_issue(issue_key, selected.account_id, function(ok, err)
				if not ok then
					statusline.notify("error", err or "Assign failed")
					done(nil, err or "Assign failed")
					return
				end

				if selected.account_id == nil then
					statusline.notify("success", string.format("Unassigned %s", issue_key), 1200)
					done({ issue_key = issue_key }, nil)
					return
				end

				statusline.notify("success", string.format("Assigned %s to %s", issue_key, selected.display_name), 1200)
				done({ issue_key = issue_key }, nil)
			end)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function reporter_available(ctx)
	return has_issue_key(ctx)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function reporter(ctx, done)
	local issue = assert(ctx.issue)

	local issue_key = issue.key
	local current_reporter_key =
		vim.trim(tostring(type(issue.reporter) == "table" and issue.reporter.display_name or "")):lower()

	local function to_picker_items(users)
		local items = {}
		for _, user in ipairs(users or {}) do
			local user_name = vim.trim(tostring(user.display_name or "")):lower()
			if user_name ~= current_reporter_key then
				table.insert(items, { id = user.account_id or "", label = user.display_name or "", value = user })
			end
		end
		return items
	end

	async_picker.open({
		title = string.format("Reporter for %s", issue_key),
		prompt = "Search users",
		initial_items = {},
		debounce_ms = 250,
		cache_ttl_ms = 60000,
		fetch_on_open = false,
		format_item = function(item)
			return string.format("%s %s", icons.general("user"), item.label)
		end,
		fetch = function(fetch_ctx, fetch_done)
			users_api.get_assignable_users(
				{ issue_key = issue_key, project = nil },
				fetch_ctx.query,
				function(users, err)
					if err then
						fetch_done(nil, err)
						return
					end
					fetch_done(to_picker_items(users), nil)
				end
			)
		end,
		on_select = function(item)
			local selected = item.value
			statusline.notify("loading", string.format("Changing reporter for %s...", issue_key))
			users_api.change_reporter(issue_key, selected.account_id, function(ok, err)
				if not ok then
					statusline.notify("error", err or "Reporter change failed")
					done(nil, err or "Reporter change failed")
					return
				end

				statusline.notify(
					"success",
					string.format("Reporter for %s changed to %s", issue_key, selected.display_name),
					1200
				)
				done({ issue_key = issue_key }, nil)
			end)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function delete_issue_available(ctx)
	return has_issue_key(ctx)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function delete_issue(ctx, done)
	local issue = assert(ctx.issue)

	local issue_key = issue.key
	vim.ui.input({
		prompt = string.format("Delete issue %s? [y/N]: ", issue_key),
	}, function(input)
		if input == nil then
			done(nil, nil)
			return
		end

		if vim.trim(tostring(input)):lower() ~= "y" then
			done(nil, nil)
			return
		end

		statusline.notify("loading", string.format("Deleting %s...", issue_key))
		issues_api.delete_issue(issue_key, function(ok, err)
			if not ok then
				statusline.notify("error", err or "Delete failed")
				done(nil, err or "Delete failed")
				return
			end

			statusline.notify("success", string.format("Deleted %s", issue_key), 1200)
			done({ issue_key = issue_key, removed = true }, nil)
		end)
	end)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function edit_issue_available(ctx)
	return has_issue_key(ctx)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function edit_issue(ctx, done)
	local issue = assert(ctx.issue)

	local issue_key = issue.key
	local adf = require("atlas.issues.providers.jira.converted.adf")
	local md_to_adf = require("atlas.issues.providers.jira.converted.markdown")
	local issue_editor = require("atlas.issues.create.jira.issue")

	local function open_editor(initial_description)
		issue_editor.open(function(fields, submit_done)
			local is_server = config.jira_config().api_type == "server"

			local desc = fields.description
			local payload = {
				summary = fields.summary,
				description = type(desc) == "string" and (is_server and desc or md_to_adf.to_adf(desc)) or vim.NIL,
			}

			if fields.issue_type and fields.issue_type.id and fields.issue_type.id ~= "" then
				payload.issuetype = { id = fields.issue_type.id }
			end

			if fields.assignee and fields.assignee.account_id then
				payload.assignee = is_server and { name = fields.assignee.account_id }
					or { id = fields.assignee.account_id }
			else
				payload.assignee = vim.NIL
			end

			statusline.notify("loading", string.format("Updating issue %s...", issue_key))
			issues_api.update_issue(issue_key, payload, function(ok, err)
				if not ok then
					local message = err or "Failed to update issue"
					statusline.notify("error", message)
					submit_done(false, message)
					done(nil, message)
					return
				end

				submit_done(true, nil)
				vim.schedule(function()
					done({ issue_key = issue_key }, nil)
				end)
			end)
		end, {
			summary = tostring(issue.summary or ""),
			description = initial_description,
			assignee = issue.assignee,
			reporter = issue.reporter,
			project = issue.project and issue.project.key or "",
			issue_key = issue.key,
			issue_type = issue.type,
		}, {
			current_user = ctx.current_user,
			preview_fn = function(markdown)
				local utils = require("atlas.ui.shared.utils")
				return utils.encode_pretty_json(md_to_adf.to_adf(markdown))
			end,
		})
	end

	statusline.notify("loading", string.format("Loading description for %s...", issue_key))
	issues_api.get_issue_description(issue_key, function(description, err)
		if err then
			statusline.notify("warn", string.format("Failed loading description for %s", issue_key), 1200)
			open_editor("")
			return
		end

		statusline.notify("success", string.format("Loaded description for %s", issue_key), 1200)
		if type(description) == "table" then
			open_editor(adf.to_markdown(description))
			return
		elseif type(description) == "string" then
			-- Description is a sting in Jira server API
			open_editor(description)
			return
		end
		open_editor("")
	end)
end

---@param context AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function create_issue(context, done)
	local projects_api = require("atlas.issues.providers.jira.api.projects")
	local md_to_adf = require("atlas.issues.providers.jira.converted.markdown")
	local issue_editor = require("atlas.issues.create.jira.issue")
	local function open_created_issue(key)
		vim.schedule(function()
			require("atlas.commands.open").open(key)
		end)
	end
	local function run_create(project_key)
		issue_editor.open(function(fields, submit_done)
			local issue_type = fields.issue_type
			local issue_type_id = issue_type and tostring(issue_type.id or "") or ""
			local issue_type_name = issue_type and tostring(issue_type.name or "") or ""

			local api_fields = {
				project = { key = fields.project },
				summary = fields.summary,
			}

			if issue_type_id ~= "" then
				api_fields.issuetype = { id = issue_type_id }
			elseif issue_type_name ~= "" then
				api_fields.issuetype = { name = issue_type_name }
			else
				statusline.notify("error", "Issue type is required")
				submit_done(false, "Issue type is required")
				done(nil, "Issue type is required")
				return
			end

			local is_server = config.jira_config().api_type == "server"
			if fields.reporter and fields.reporter.account_id then
				api_fields.reporter = is_server and { name = fields.reporter.account_id }
					or { accountId = fields.reporter.account_id }
			end

			local desc = fields.description
			if type(desc) == "string" then
				api_fields.description = is_server and desc or md_to_adf.to_adf(desc)
			end

			if fields.assignee and fields.assignee.account_id then
				api_fields.assignee = is_server and { name = fields.assignee.account_id }
					or { id = fields.assignee.account_id }
			end

			local raw_desc = desc
			-- Jira Server workaround: some configs omit `description` from the create screen.
			-- See: https://support.atlassian.com/jira/kb/can-not-create-issue-via-rest-api-field-xxx-cannot-be-set-it-is-not-on-the-appropriate-screen-or-unknown-when-using-workflow-property-jirapermissioncreateclonedenied/
			local function commit_create(payload, was_retry)
				issues_api.create_issue(payload, function(result, err)
					if err then
						if
							not was_retry
							and type(raw_desc) == "string"
							and err:find("Field 'description' cannot be set", 1, true)
						then
							local retry = vim.deepcopy(payload)
							retry.description = nil
							commit_create(retry, true)
							return
						end
						statusline.notify("error", err)
						submit_done(false, err)
						done(nil, err)
						return
					end

					if result and result.key then
						if was_retry and type(raw_desc) == "string" then
							local update = { description = raw_desc }
							issues_api.update_issue(result.key, update, function(ok)
								if ok then
									notify.info(string.format("Created %s", result.key), { timeout = 2000 })
									submit_done(true, nil)
									done({ issue_key = result.key }, nil)
									open_created_issue(result.key)
								else
									notify.warn("Issue created but failed to set description", { timeout = 3000 })
									submit_done(true, "Description not set")
									done({ issue_key = result.key }, nil)
									open_created_issue(result.key)
								end
							end)
							return
						end

						notify.info(string.format("Created %s", result.key), { timeout = 2000 })
						submit_done(true, nil)
						done({ issue_key = result.key }, nil)
						open_created_issue(result.key)
						return
					end

					statusline.notify("error", "Invalid response")
					submit_done(false, "Invalid response")
					done(nil, "Invalid response")
				end)
			end

			commit_create(api_fields, false)
		end, {
			summary = "",
			description = nil,
			assignee = nil,
			reporter = nil,
			project = project_key,
			issue_key = nil,
			issue_type = nil,
		}, {
			current_user = context.current_user,
			preview_fn = function(markdown)
				local utils = require("atlas.ui.shared.utils")
				return utils.encode_pretty_json(md_to_adf.to_adf(markdown))
			end,
		})
	end

	local all_items = nil

	async_picker.open({
		title = "Create Issue",
		prompt = "Select project",
		debounce_ms = 0,
		identifier = "jira_creatable_projects",
		format_item = function(item)
			local provider_icon, provider_hl = icons.issues_provider("jira", "provider")
			local project = item.value
			local category_name = project.category and project.category.name or ""
			if category_name ~= "" then
				return string.format("%s %s - %s (%s)", provider_icon, item.label, project.name, category_name),
					provider_hl
			end
			return string.format("%s %s - %s", provider_icon, item.label, project.name), provider_hl
		end,
		fetch = function(fetch_ctx, fetch_done)
			if all_items then
				local query = vim.trim(fetch_ctx.query):lower()
				if query == "" then
					fetch_done(all_items, nil)
					return
				end
				local filtered = {}
				for _, item in ipairs(all_items) do
					local project = item.value
					local haystack = (
						item.label
						.. " "
						.. (project.name or "")
						.. " "
						.. (project.category and project.category.name or "")
					):lower()
					if haystack:find(query, 1, true) then
						table.insert(filtered, item)
					end
				end
				fetch_done(filtered, nil)
				return
			end

			projects_api.get_projects({ maxResults = 50, total = 2, status = "live" }, function(groups, err)
				if fetch_ctx.signal.cancelled then
					return
				end
				if err or not groups then
					fetch_done(nil, err or "Failed to load projects")
					return
				end

				local projects = {}
				for _, group in ipairs(groups) do
					for _, project in ipairs(group.projects or {}) do
						table.insert(projects, project)
					end
				end

				local project_ids = {}
				for _, project in ipairs(projects) do
					local project_id = tonumber(project.id)
					if project_id then
						table.insert(project_ids, project_id)
					end
				end

				users_api.get_permissions_bulk({
					permissions = { "CREATE_ISSUES" },
					project_ids = project_ids,
				}, function(permission_map, perm_err)
					if fetch_ctx.signal.cancelled then
						return
					end
					if perm_err or not permission_map then
						fetch_done(nil, perm_err or "Failed to load project permissions")
						return
					end

					local allowed_map = permission_map.CREATE_ISSUES or {}
					all_items = {}
					for _, project in ipairs(projects) do
						local project_id = tonumber(project.id)
						if project_id and allowed_map[project_id] == true then
							table.insert(all_items, {
								id = tostring(project.id or ""),
								label = tostring(project.key or ""),
								value = project,
							})
						end
					end

					fetch_done(all_items, nil)
				end)
			end)
		end,
		on_select = function(item)
			run_create(item.value.key)
		end,
		on_cancel = function()
			notify.info("Create issue cancelled", { timeout = 1200 })
			done(nil, nil)
		end,
	})
end

---@param _ AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function search_query_issue(_, done)
	async_picker.open({
		title = "Search Issues",
		prompt = "Issue name or key",
		debounce_ms = 200,
		identifier = "jira_issue_picker_search",
		cache_ttl_ms = 30000,
		fetch_on_open = true,
		format_item = function(item)
			local provider_icon = icons.issues_provider("jira", "provider")
			return string.format("%s %s", provider_icon, tostring(item.label or "")), "AtlasJiraKey"
		end,
		fetch = function(fetch_ctx, fetch_done)
			local query = vim.trim(fetch_ctx.query)
			issues_api.search_issue(query, function(items, err)
				if fetch_ctx.signal.cancelled then
					return
				end

				if err ~= nil or items == nil then
					fetch_done(nil, err or "Failed to search tickets")
					return
				end

				local picker_items = {}
				for _, issue in ipairs(items) do
					table.insert(picker_items, {
						id = tostring(issue.id or issue.key),
						label = string.format("%s - %s", issue.key, issue.summary),
						secondary = issue.key,
						value = issue,
					})
				end

				fetch_done(picker_items, nil)
			end)
		end,
		on_select = function(item)
			local issue = item.value
			local issue_key = tostring((issue or {}).key or "")
			if issue_key == "" then
				statusline.notify("error", "Selected issue is missing key")
				done(nil, "Selected issue is missing key")
				return
			end

			require("atlas.issues.providers.jira.completion.search").open_query(string.format('key = "%s"', issue_key))
			done(nil, nil)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param _ AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function manage_templates(_, done)
	local template_store = require("atlas.issues.templates")
	local markdown_editor = require("atlas.ui.popups.editor")

	local options = {
		{ id = "create", label = "Create template" },
		{ id = "edit", label = "Edit template" },
	}

	vim.ui.select(options, {
		prompt = "Templates",
		kind = "atlas_jira_template_actions",
		format_item = function(item)
			return tostring((item and item.label) or "")
		end,
	}, function(choice)
		if choice == nil then
			done(nil, nil)
			return
		end

		if choice.id == "create" then
			local finalized = false
			local function finish(err)
				if finalized then
					return
				end
				finalized = true
				if err then
					statusline.notify("error", err)
				end
				done(nil, err)
			end

			markdown_editor.open({
				key = string.format("template_new_%d", vim.loop.hrtime()),
				title = " New Issue Template ",
				initial_text = "",
				on_save = function(text)
					local markdown = tostring(text or "")
					vim.ui.input({ prompt = "Template name: " }, function(name_input)
						if name_input == nil then
							finish()
							return
						end

						local name = vim.trim(tostring(name_input))
						if name == "" then
							finish("Template name is required")
							return
						end

						local ok, write_err, existed, normalized_name =
							template_store.write(name, markdown, { overwrite = false })
						if ok then
							finish()
							return
						end

						if existed then
							vim.ui.input({
								prompt = string.format(
									'Template "%s" exists. Overwrite? [y/N]: ',
									tostring(normalized_name or name)
								),
							}, function(confirm)
								if confirm == nil or vim.trim(tostring(confirm)):lower() ~= "y" then
									finish()
									return
								end

								local overwrite_ok, overwrite_err =
									template_store.write(name, markdown, { overwrite = true })
								if not overwrite_ok then
									finish(overwrite_err or "Failed to overwrite template")
									return
								end

								finish()
							end)
							return
						end

						finish(write_err or "Failed to create template")
					end)
				end,
				on_cancel = function()
					finish()
				end,
			})
			return
		end

		local templates, list_err = template_store.list()
		if list_err then
			statusline.notify("error", list_err)
			done(nil, list_err)
			return
		end

		if templates == nil or #templates == 0 then
			done(nil, nil)
			return
		end

		vim.ui.select(templates, {
			prompt = "Edit template",
			kind = "atlas_jira_templates",
			format_item = function(item)
				return tostring((item and item.name) or "")
			end,
		}, function(selected)
			if selected == nil then
				done(nil, nil)
				return
			end

			local template_name = tostring(selected.name or "")
			if template_name == "" then
				statusline.notify("error", "Invalid template selected")
				done(nil, "Invalid template selected")
				return
			end

			local content, read_err = template_store.read(template_name)
			if read_err then
				statusline.notify("error", read_err)
				done(nil, read_err)
				return
			end

			local finalized = false
			local function finish(err)
				if finalized then
					return
				end
				finalized = true
				if err then
					statusline.notify("error", err)
				end
				done(nil, err)
			end

			local key = ("template_" .. template_name):gsub("[^%w%-_]+", "_")
			markdown_editor.open({
				key = key,
				title = string.format(" Template: %s ", template_name),
				initial_text = content,
				actions = {
					{
						key = "<C-d>",
						description = "delete",
						callback = function(editor_ctx)
							vim.ui.input({
								prompt = string.format('Delete template "%s"? [y/N]: ', template_name),
							}, function(confirm)
								if confirm == nil or vim.trim(tostring(confirm)):lower() ~= "y" then
									return
								end

								local deleted, delete_err = template_store.delete(template_name)
								if not deleted then
									finish(delete_err or "Failed to delete template")
									return
								end

								editor_ctx.close()
								finish()
							end)
						end,
					},
				},
				on_save = function(text)
					local ok, write_err = template_store.write(template_name, text, { overwrite = true })
					if not ok then
						finish(write_err or "Failed to update template")
						return
					end

					finish()
				end,
				on_cancel = function()
					finish()
				end,
			})
		end)
	end)
end

---@param _ AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function search(_, done)
	require("atlas.issues.providers.jira.completion.search").open(current_jql())
	done(nil, nil)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function browse_issue_available(ctx)
	return has_issue_key(ctx)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function browse_issue(ctx, done)
	local issue = assert(ctx.issue)

	local base_url = tostring(config.jira_config().base_url or ""):gsub("/$", "")
	local issue_key = tostring(issue.key or "")
	if base_url == "" or issue_key == "" then
		statusline.notify("error", "No URL found for issue")
		done(nil, "No URL found for issue")
		return
	end

	vim.ui.open(string.format("%s/browse/%s", base_url, issue_key))
	statusline.notify("success", string.format("Opened %s in browser", issue_key), 1200)
	done(nil, nil)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function copy_issue_url_available(ctx)
	return has_issue_key(ctx)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function copy_issue_url(ctx, done)
	local issue = assert(ctx.issue)

	local base_url = tostring(config.jira_config().base_url or ""):gsub("/$", "")
	local issue_key = tostring(issue.key or "")
	local url = (base_url ~= "" and issue_key ~= "") and string.format("%s/browse/%s", base_url, issue_key) or ""
	if url == "" then
		statusline.notify("error", "No URL found for issue")
		done(nil, "No URL found for issue")
		return
	end

	vim.fn.setreg("+", url)
	vim.fn.setreg('"', url)
	statusline.notify("success", "Copied issue URL", 1200)
	done(nil, nil)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function toggle_subscription_available(ctx)
	if not has_issue_key(ctx) then
		return false, "No issue selected"
	end
	return true, nil
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function toggle_subscription(ctx, done)
	local svc = require("atlas.issues.providers.jira.api.service")
	local issue = assert(ctx.issue)
	local issue_key = tostring(issue.key or "")
	statusline.notify("loading", issue.is_subscribed and "Unsubscribing..." or "Subscribing...")

	local function finish(subscribed, err)
		if err then
			statusline.notify("error", tostring(err))
			done(nil, tostring(err))
			return
		end
		issue.is_subscribed = subscribed == true
		statusline.notify("success", issue.is_subscribed and "Subscribed" or "Unsubscribed", 1200)
		done({ issue_key = issue.key }, nil)
	end

	if issue.is_subscribed ~= true then
		svc.request("POST", "/issue/" .. issue_key .. "/watchers", nil, function(_, err)
			finish(err == nil and true or nil, err)
		end)
		return
	end

	local function unsubscribe(account_id)
		local param_name = "accountId"
		if config.jira_config().api_type == "server" then
			param_name = "username"
		end

		svc.request(
			"DELETE",
			string.format("/issue/%s/watchers?%s=%s", issue_key, param_name, account_id),
			nil,
			function(_, err)
				finish(err == nil and false or nil, err)
			end
		)
	end

	local st = require("atlas.issues.state")
	local current = st.current_user
	if current and tostring(current.account_id or "") ~= "" then
		unsubscribe(current.account_id)
		return
	end

	require("atlas.issues.providers.jira.api.users").get_myself(function(user, err)
		if err or not user or user.account_id == "" then
			finish(nil, err or "Failed to fetch Jira user")
			return
		end
		unsubscribe(user.account_id)
	end)
end

register({
	id = "transition",
	label = "Transition",
	is_available = transition_available,
	run = transition,
})
register({
	id = "assign",
	label = "Change assignee",
	is_available = assign_available,
	run = assign,
})
register({
	id = "reporter",
	label = "Change reporter",
	is_available = reporter_available,
	run = reporter,
})
register({
	id = "delete_issue",
	label = "Delete Issue",
	is_available = delete_issue_available,
	run = delete_issue,
})
register({
	id = "edit_issue",
	label = "Edit Issue",
	is_available = edit_issue_available,
	run = edit_issue,
})
register({
	id = "create_issue",
	label = "Create Issue",
	run = create_issue,
})
register({
	id = "search_query_issue",
	label = "Search Issue",
	run = search_query_issue,
})
register({
	id = "manage_templates",
	label = "Manage Issue Templates",
	run = manage_templates,
})
register({
	id = "search",
	label = "Search JQL",
	run = search,
})
register({
	id = "browse_issue",
	label = "Open Issue In Browser",
	hidden = true,
	is_available = browse_issue_available,
	run = browse_issue,
})
register(actions.copy_issue_key)
register({
	id = "copy_issue_url",
	label = "Copy Issue URL",
	hidden = true,
	is_available = copy_issue_url_available,
	run = copy_issue_url,
})
register({
	id = "toggle_subscription",
	label = "Toggle subscription",
	is_available = toggle_subscription_available,
	run = toggle_subscription,
})

---@param id AtlasJiraIssueActionId
---@return AtlasIssueAction|nil
function M.find(id)
	for _, action in ipairs(ACTIONS) do
		if action.id == id then
			return action
		end
	end
	return nil
end

return M
