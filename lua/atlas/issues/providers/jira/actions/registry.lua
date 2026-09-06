local M = {}

local actions = require("atlas.issues.actions")
local icons = require("atlas.ui.shared.icons")
local picker = require("atlas.ui.picker")
local issues_api = require("atlas.issues.providers.jira.api.issues")
local projects_api = require("atlas.issues.providers.jira.api.projects")
local service = require("atlas.issues.providers.jira.api.service")
local notify = require("atlas.core.notify")
local transitions_api = require("atlas.issues.providers.jira.api.transitions")
local users_api = require("atlas.issues.providers.jira.api.users")
local issues_state = require("atlas.issues.state")

---@param ctx AtlasIssueActionContext
---@return boolean
local function has_issue_key(ctx)
	local issue = ctx.issue
	if issue == nil then
		return false
	end
	local key = tostring(issue.key or "")
	return key ~= ""
end

---@return string
local function current_jql()
	return issues_state.query
end

---@type AtlasIssueAction[]
local ACTIONS = {}
M.items = ACTIONS

---@param action AtlasIssueAction
local function register(action)
	table.insert(ACTIONS, action)
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

	picker.search({
		title = string.format("Transition %s", issue_key),
		debounce_ms = 0,
		format_item = function(item)
			local transition_value = item.value
			local category = transition_value.to_status_category
			local icon = (category and status_category_icons[category]) or icons.fallback()
			return string.format("%s %s", icon, item.label)
		end,
		fetch = function(query, fetch_done)
			if all_items then
				local normalized = vim.trim(query):lower()
				if normalized == "" then
					fetch_done(all_items, nil)
					return
				end
				local filtered = {}
				for _, item in ipairs(all_items) do
					if item.label:lower():find(normalized, 1, true) then
						table.insert(filtered, item)
					end
				end
				fetch_done(filtered, nil)
				return
			end

			return transitions_api.get_transitions(issue_key, function(transitions, err)
				if err ~= nil or transitions == nil then
					fetch_done(nil, err or "Failed to load transitions")
					return
				end

				all_items = {}
				for _, candidate in ipairs(transitions) do
					local to_status = tostring((candidate and candidate.to_status_name) or "")
					if current_status == "" or to_status == "" or to_status ~= current_status then
						table.insert(all_items, {
							id = tostring(candidate.id or ""),
							label = tostring(candidate.name or ""),
							value = candidate,
						})
					end
				end
				fetch_done(all_items, nil)
			end)
		end,
		on_select = function(item)
			local selected = item.value
			notify.loading(string.format("Transitioning %s...", issue_key))
			transitions_api.transition_issue(issue_key, selected.id, function(ok, err)
				if not ok then
					notify.error(err or "Transition failed")
					done(nil, err or "Transition failed")
					return
				end

				notify.success(
					string.format("Transitioned %s to %s", issue_key, selected.name or ""),
					{ timeout = 1200 }
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
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function assign(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue JiraIssue

	local issue_key = issue.key
	local issue_project_key = issue.project and issue.project.key or nil
	local current_assignee_key = vim.trim(tostring(issue.assignee and issue.assignee.display_name or "")):lower()

	local function to_picker_items(users)
		local items = {}
		local current_user = ctx.current_user
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

	picker.search({
		title = string.format("Assign %s", issue_key),
		initial_items = to_picker_items({}),
		fetch_on_open = false,
		format_item = function(item)
			if item.id == "__unassign__" then
				return item.label
			end
			return string.format("%s %s", icons.general("user"), item.label)
		end,
		fetch = function(query, fetch_done)
			return users_api.get_assignable_users(
				{ issue_key = issue_key, project = issue_project_key },
				query,
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
			notify.loading(string.format("Assigning %s...", issue_key))
			users_api.assign_issue(issue_key, selected.account_id, function(ok, err)
				if not ok then
					notify.error(err or "Assign failed")
					done(nil, err or "Assign failed")
					return
				end

				if selected.account_id == nil then
					notify.success(string.format("Unassigned %s", issue_key), { timeout = 1200 })
					done({ issue_key = issue_key }, nil)
					return
				end

				notify.success(string.format("Assigned %s to %s", issue_key, selected.display_name), { timeout = 1200 })
				done({ issue_key = issue_key }, nil)
			end)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function reporter(ctx, done)
	local issue = assert(ctx.issue)

	local issue_key = issue.key
	local current_reporter_key = vim.trim(tostring(issue.reporter and issue.reporter.display_name or "")):lower()

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

	picker.search({
		title = string.format("Reporter for %s", issue_key),
		fetch_on_open = false,
		format_item = function(item)
			return string.format("%s %s", icons.general("user"), item.label)
		end,
		fetch = function(query, fetch_done)
			return users_api.get_assignable_users({ issue_key = issue_key, project = nil }, query, function(users, err)
				if err then
					fetch_done(nil, err)
					return
				end
				fetch_done(to_picker_items(users), nil)
			end)
		end,
		on_select = function(item)
			local selected = item.value
			notify.loading(string.format("Changing reporter for %s...", issue_key))
			users_api.change_reporter(issue_key, selected.account_id, function(ok, err)
				if not ok then
					notify.error(err or "Reporter change failed")
					done(nil, err or "Reporter change failed")
					return
				end

				notify.success(
					string.format("Reporter for %s changed to %s", issue_key, selected.display_name),
					{ timeout = 1200 }
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

		notify.loading(string.format("Deleting %s...", issue_key))
		issues_api.delete_issue(issue_key, function(ok, err)
			if not ok then
				notify.error(err or "Delete failed")
				done(nil, err or "Delete failed")
				return
			end

			notify.success(string.format("Deleted %s", issue_key), { timeout = 1200 })
			done({ issue_key = issue_key, removed = true }, nil)
		end)
	end)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function edit_issue(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue JiraIssue

	local issue_key = issue.key
	local md_to_adf = require("atlas.issues.providers.jira.converted.markdown")
	local issue_editor = require("atlas.issues.create.jira.issue")

	local function open_editor(initial_description)
		issue_editor.open(function(fields, submit_done)
			local is_server = service.is_server()

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

			notify.loading(string.format("Updating issue %s...", issue_key))
			issues_api.update_issue(issue_key, payload, function(ok, err)
				if not ok then
					local message = err or "Failed to update issue"
					notify.error(message)
					submit_done(false, message)
					done(nil, message)
					return
				end

				notify.success(string.format("Updated %s", issue_key), { timeout = 1200 })
				submit_done(true, nil)
				vim.schedule(function()
					done({ issue_key = issue_key }, nil)
				end)
			end)
		end, {
			summary = tostring(issue.title or ""),
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

	notify.loading(string.format("Loading description for %s...", issue_key))
	issues_api.fetch_issue({ key = issue_key }, { force_refresh = true }, function(details, err)
		if err or details == nil then
			notify.warn(string.format("Failed loading description for %s", issue_key), { timeout = 1200 })
			open_editor("")
			return
		end

		notify.success(string.format("Loaded description for %s", issue_key), { timeout = 1200 })
		open_editor(details.description)
	end)
end

---@param context AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function create_issue(context, done)
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
				notify.error("Issue type is required")
				submit_done(false, "Issue type is required")
				done(nil, "Issue type is required")
				return
			end

			local is_server = service.is_server()
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
						notify.error(err)
						submit_done(false, err)
						done(nil, err)
						return
					end

					if result and result.key then
						if was_retry and type(raw_desc) == "string" then
							local update = { description = raw_desc }
							issues_api.update_issue(result.key, update, function(ok)
								if ok then
									notify.info(
										string.format("Created %s", result.key),
										{ timeout = 2000, vim_notify = true }
									)
									submit_done(true, nil)
									done({ issue_key = result.key }, nil)
									open_created_issue(result.key)
								else
									notify.warn(
										"Issue created but failed to set description",
										{ timeout = 3000, vim_notify = true }
									)
									submit_done(true, "Description not set")
									done({ issue_key = result.key }, nil)
									open_created_issue(result.key)
								end
							end)
							return
						end

						notify.info(string.format("Created %s", result.key), { timeout = 2000, vim_notify = true })
						submit_done(true, nil)
						done({ issue_key = result.key }, nil)
						open_created_issue(result.key)
						return
					end

					notify.error("Invalid response")
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

	picker.search({
		title = "Create Issue",
		debounce_ms = 0,
		format_item = function(item)
			local project = item.value
			local label =
				string.format("%s %s - %s", icons.issues_provider("jira", "provider"), item.label, project.name)
			local category = project.category and project.category.name or ""
			return category ~= "" and label .. " (" .. category .. ")" or label
		end,
		fetch = function(query, fetch_done)
			if all_items then
				query = vim.trim(query):lower()
				fetch_done(
					vim.tbl_filter(function(item)
						local project = item.value
						local category = project.category and project.category.name or ""
						local text = string.format("%s %s %s", item.label, project.name, category):lower()
						return text:find(query, 1, true) ~= nil
					end, all_items),
					nil
				)
				return
			end

			return projects_api.get_projects({ maxResults = 50, total = 2, status = "live" }, function(groups, err)
				if err or not groups then
					fetch_done(nil, err or "Failed to load projects")
					return
				end

				local projects = {}
				for _, group in ipairs(groups) do
					vim.list_extend(projects, group.projects)
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
			notify.info("Create issue cancelled", { timeout = 1200, vim_notify = true })
			done(nil, nil)
		end,
	})
end

---@param project JiraIssueProject|nil
---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function search_issues(project, ctx, done)
	picker.search({
		title = project and "Search " .. project.key .. " Issues" or "Search Issues",
		debounce_ms = 200,
		format_item = function(item)
			return tostring(item.label or "")
		end,
		preview_item = function(item, preview_done)
			local issue = item.value
			return issues_api.fetch_issue({ key = issue.key }, nil, function(details, err)
				if err or details == nil then
					preview_done({ title = issue.key, lines = { err or "Failed to load issue" } })
					return
				end
				---@cast details JiraIssueDetails
				local assignee = details.assignees[1]
				local status = "**Status:** " .. (details.status or "Unknown")
				local assignee_name = "**Assignee:** " .. (assignee and assignee.display_name or "Unassigned")
				local column = math.max(vim.fn.strdisplaywidth(status), vim.fn.strdisplaywidth(assignee_name)) + 4
				local lines = {
					status
						.. string.rep(" ", column - vim.fn.strdisplaywidth(status))
						.. "**Priority:** "
						.. (details.priority or "None"),
					assignee_name
						.. string.rep(" ", column - vim.fn.strdisplaywidth(assignee_name))
						.. "**Reporter:** "
						.. (details.reporter and details.reporter.display_name or "Unknown"),
				}
				local labels = vim.tbl_map(function(label)
					return label.name
				end, details.labels)
				if #labels > 0 then
					table.insert(lines, "**Labels:** " .. table.concat(labels, ", "))
				end
				for _, field in ipairs(details.custom_fields) do
					table.insert(lines, string.format("**%s:** %s", field.name, field.formatted))
				end
				table.insert(lines, "")
				table.insert(lines, "## Description")
				table.insert(lines, "")
				local description = vim.trim(details.description)
				vim.list_extend(
					lines,
					vim.split(description ~= "" and description or "No description", "\n", { plain = true })
				)
				preview_done({
					title = string.format("%s - %s", issue.key, issue.title),
					lines = lines,
				})
			end)
		end,
		fetch = function(query, fetch_done)
			return issues_api.search_issue(project, vim.trim(query), function(items, err)
				if err ~= nil or items == nil then
					fetch_done(nil, err or "Failed to search tickets")
					return
				end

				local picker_items = {}
				for _, issue in ipairs(items) do
					table.insert(picker_items, {
						id = tostring(issue.id or issue.key),
						label = string.format("%s - %s", issue.key, issue.title),
						value = issue,
					})
				end

				fetch_done(picker_items, nil)
			end)
		end,
		on_select = function(item)
			local issue = item.value
			require("atlas.issues.ui.detail").open_ref({ key = issue.key }, { provider = ctx.provider })
			done(nil, nil)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function search_issue(ctx, done)
	return projects_api.get_projects({ maxResults = 50, total = 2, status = "live" }, function(groups, err)
		if err or not groups then
			notify.error(err or "Failed to load projects")
			done(nil, err or "Failed to load projects")
			return
		end

		local projects = {}
		for _, group in ipairs(groups) do
			vim.list_extend(projects, group.projects)
		end
		if #projects <= 1 then
			search_issues(projects[1], ctx, done)
			return
		end

		local items = vim.tbl_map(function(project)
			return { id = project.id, label = project.key, value = project }
		end, projects)
		table.insert(items, 1, { id = "all", label = "All projects" })
		picker.search({
			title = "Search Issues - Project",
			initial_items = items,
			fetch_on_open = false,
			debounce_ms = 0,
			format_item = function(item)
				local project = item.value
				if not project then
					return icons.issues_provider("jira", "provider") .. " " .. item.label
				end
				local label =
					string.format("%s %s - %s", icons.issues_provider("jira", "provider"), item.label, project.name)
				local category = project.category and project.category.name or ""
				return category ~= "" and label .. " (" .. category .. ")" or label
			end,
			fetch = function(query, fetch_done)
				query = vim.trim(query):lower()
				fetch_done(
					vim.tbl_filter(function(item)
						local project = item.value
						local name = project and project.name or ""
						local category = project and project.category and project.category.name or ""
						local text = string.format("%s %s %s", item.label, name, category):lower()
						return text:find(query, 1, true) ~= nil
					end, items),
					nil
				)
			end,
			on_select = function(item)
				search_issues(item.value, ctx, done)
			end,
			on_cancel = function()
				done(nil, nil)
			end,
		})
	end)
end

---@param _ AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function open_project(_, done)
	return projects_api.get_projects({ maxResults = 50, total = 2, status = "live" }, function(groups, err)
		if err or not groups then
			notify.error(err or "Failed to load projects")
			done(nil, err or "Failed to load projects")
			return
		end

		local projects = {}
		for _, group in ipairs(groups) do
			vim.list_extend(projects, group.projects)
		end
		if #projects == 0 then
			notify.info("No Jira projects found")
			done(nil, nil)
			return
		end
		picker.select({
			title = "Open Project",
			items = projects,
			format_item = function(project)
				local label =
					string.format("%s %s - %s", icons.issues_provider("jira", "provider"), project.key, project.name)
				local category = project.category and project.category.name or ""
				return category ~= "" and label .. " (" .. category .. ")" or label
			end,
			on_select = function(project)
				if not project then
					done(nil, nil)
					return
				end
				require("atlas.issues.providers.jira.completion.search").open_query(
					"project = " .. project.key .. " ORDER BY updated DESC"
				)
				done(nil, nil)
			end,
		})
	end)
end

---@param _ AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function search_jql(_, done)
	require("atlas.issues.providers.jira.completion.search").open(current_jql())
	done(nil, nil)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function browse_issue(ctx, done)
	local issue = assert(ctx.issue)

	local base_url = service.base_url():gsub("/$", "")
	local issue_key = tostring(issue.key or "")
	if base_url == "" or issue_key == "" then
		notify.error("No URL found for issue")
		done(nil, "No URL found for issue")
		return
	end

	vim.ui.open(string.format("%s/browse/%s", base_url, issue_key))
	notify.success(string.format("Opened %s in browser", issue_key), { timeout = 1200 })
	done(nil, nil)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function copy_issue_url(ctx, done)
	local issue = assert(ctx.issue)

	local base_url = service.base_url():gsub("/$", "")
	local issue_key = tostring(issue.key or "")
	local url = (base_url ~= "" and issue_key ~= "") and string.format("%s/browse/%s", base_url, issue_key) or ""
	if url == "" then
		notify.error("No URL found for issue")
		done(nil, "No URL found for issue")
		return
	end

	vim.fn.setreg("+", url)
	vim.fn.setreg('"', url)
	notify.success("Copied issue URL", { timeout = 1200 })
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
	notify.loading(issue.is_subscribed and "Unsubscribing..." or "Subscribing...")

	local function finish(subscribed, err)
		if err then
			notify.error(tostring(err))
			done(nil, tostring(err))
			return
		end
		issue.is_subscribed = subscribed == true
		notify.success(issue.is_subscribed and "Subscribed" or "Unsubscribed", { timeout = 1200 })
		done({ issue_key = issue.key }, nil)
	end

	if issue.is_subscribed ~= true then
		svc.request("POST", "/issue/" .. issue_key .. "/watchers", nil, function(_, err)
			finish(err == nil and true or nil, err)
		end, { action = "Subscribe to issue", issue_key = issue_key })
		return
	end

	local function unsubscribe(account_id)
		local param_name = "accountId"
		if service.is_server() then
			param_name = "username"
		end

		svc.request(
			"DELETE",
			string.format("/issue/%s/watchers?%s=%s", issue_key, param_name, account_id),
			nil,
			function(_, err)
				finish(err == nil and false or nil, err)
			end,
			{ action = "Unsubscribe from issue", issue_key = issue_key }
		)
	end

	local current = ctx.current_user
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
	icon = icons.action("transition"),
	is_available = has_issue_key,
	run = transition,
})
register({
	id = "assign",
	label = "Edit Assignee",
	icon = icons.action("edit"),
	is_available = has_issue_key,
	run = assign,
})
register({
	id = "reporter",
	label = "Edit Reporter",
	icon = icons.action("edit"),
	is_available = has_issue_key,
	run = reporter,
})
register({
	id = "edit_issue",
	label = "Edit Issue",
	icon = icons.action("edit"),
	is_available = has_issue_key,
	run = edit_issue,
})
register({
	id = "search",
	label = "Search Issue",
	icon = icons.action("search"),
	run = search_issue,
})
register({
	id = "open_project",
	label = "Open Project",
	icon = icons.action("search"),
	run = open_project,
})
register({
	id = "search_jql",
	label = "Search JQL",
	icon = icons.action("search"),
	run = search_jql,
})
register(actions.manage_templates)
register({
	id = "browse_issue",
	label = "Open Issue In Browser",
	hidden = true,
	is_available = has_issue_key,
	run = browse_issue,
})
register(actions.copy_issue_key)
register({
	id = "copy_issue_url",
	label = "Copy Issue URL",
	hidden = true,
	is_available = has_issue_key,
	run = copy_issue_url,
})
register({
	id = "toggle_subscription",
	label = "Toggle subscription",
	icon = icons.action("notification"),
	is_available = toggle_subscription_available,
	run = toggle_subscription,
})
register({
	id = "create_issue",
	label = "Create Issue",
	icon = icons.action("create"),
	run = create_issue,
})
register({
	id = "delete_issue",
	label = "Delete Issue",
	icon = icons.action("delete"),
	is_available = has_issue_key,
	run = delete_issue,
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
