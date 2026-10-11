---@alias AtlasJiraIssueActionId
---| AtlasIssueActionId
---| "reporter"
---| "delete_issue"
---| "open_project"
---| "search_jql"

local M = {}

local actions = require("atlas.issues.actions")
local icons = require("atlas.ui.shared.icons")
local picker = require("atlas.ui.picker")
local issues_api = require("atlas.issues.providers.jira.api.issues")
local projects_api = require("atlas.issues.providers.jira.api.projects")
local service = require("atlas.providers.jira.client")
local notify = require("atlas.core.notify")
local transitions_api = require("atlas.issues.providers.jira.api.transitions")
local users_api = require("atlas.providers.jira.users")
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

	local function filter_items(query)
		local normalized = vim.trim(query):lower()
		if normalized == "" then
			return all_items
		end
		local filtered = {}
		for _, item in ipairs(all_items) do
			if item.label:lower():find(normalized, 1, true) then
				table.insert(filtered, item)
			end
		end
		return filtered
	end

	picker.search({
		title = string.format("Transition %s", issue_key),
		debounce_ms = 0,
		format_item = function(item)
			local icon = item.value.icon and item.value.icon.icon or icons.get("fallback")
			return icon ~= "" and string.format("%s %s", icon, item.label) or item.label
		end,
		fetch = function(query, fetch_done)
			if all_items then
				fetch_done(filter_items(query), nil)
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
							label = to_status ~= "" and to_status or candidate.name,
							value = candidate,
						})
					end
				end
				fetch_done(filter_items(query), nil)
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

				notify.success(string.format("Transitioned %s to %s", issue_key, item.label), { timeout = 1200 })
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
	local current_assignee_id = issue.assignee and issue.assignee.id or nil

	local function to_picker_items(users)
		local items = {}
		local current_user = ctx.current_user
		local current_user_id = current_user and current_user.id or nil
		local current_user_item = nil

		if current_assignee_id then
			table.insert(items, {
				id = "__unassign__",
				label = "Unassign",
				value = { id = nil, name = "Unassign" },
			})
		end

		for _, user in ipairs(users or {}) do
			if user.id ~= current_assignee_id then
				local item = { id = user.id or "", label = user.name or "", value = user }
				if current_user_id and user.id == current_user_id then
					current_user_item = item
				else
					table.insert(items, item)
				end
			end
		end

		if current_user_id and current_user_id ~= current_assignee_id then
			if not current_user_item then
				current_user_item = {
					id = current_user_id,
					label = current_user.name or "",
					value = current_user,
				}
			end
			table.insert(items, 1, current_user_item)
		end

		return items
	end

	picker.search({
		title = string.format("Assign %s", issue_key),
		size = { width = 0.3, height = 0.3 },
		initial_items = to_picker_items({}),
		fetch_on_open = false,
		format_item = function(item)
			if item.id == "__unassign__" then
				return item.label
			end
			return string.format("%s %s", icons.get("user"), item.label)
		end,
		fetch = function(query, fetch_done)
			return issues_api.get_assignable_users(
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
			issues_api.assign_issue(issue_key, selected.id, function(ok, err)
				if not ok then
					notify.error(err or "Assign failed")
					done(nil, err or "Assign failed")
					return
				end

				if selected.id == nil then
					notify.success(string.format("Unassigned %s", issue_key), { timeout = 1200 })
					done({ issue_key = issue_key }, nil)
					return
				end

				notify.success(string.format("Assigned %s to %s", issue_key, selected.name), { timeout = 1200 })
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
	local current_reporter_id = issue.reporter and issue.reporter.id or nil

	local function to_picker_items(users)
		local items = {}
		for _, user in ipairs(users or {}) do
			if user.id ~= current_reporter_id then
				table.insert(items, { id = user.id or "", label = user.name or "", value = user })
			end
		end
		return items
	end

	picker.search({
		title = string.format("Reporter for %s", issue_key),
		size = { width = 0.3, height = 0.3 },
		fetch_on_open = false,
		format_item = function(item)
			return string.format("%s %s", icons.get("user"), item.label)
		end,
		fetch = function(query, fetch_done)
			return issues_api.get_assignable_users({ issue_key = issue_key, project = nil }, query, function(users, err)
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
			issues_api.change_reporter(issue_key, selected.id, function(ok, err)
				if not ok then
					notify.error(err or "Reporter change failed")
					done(nil, err or "Reporter change failed")
					return
				end

				notify.success(
					string.format("Reporter for %s changed to %s", issue_key, selected.name),
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

	return require("atlas.issues.providers.jira.ui.editor").edit(issue, function(result, err)
		done(result and { issue_key = result.key } or nil, err)
	end)
end

---@param groups JiraProjectGroup[]
---@return JiraIssueProject[]
local function flatten_projects(groups)
	local projects = {}
	for _, group in ipairs(groups) do
		vim.list_extend(projects, group.projects)
	end
	return projects
end

---@param project JiraIssueProject
---@return string
local function format_project(project)
	local label = string.format("%s %s - %s", icons.provider_icon("jira", "issues"), project.key, project.name)
	local category = project.category and project.category.name or ""
	return category ~= "" and label .. " (" .. category .. ")" or label
end

---@param items { label: string, value?: JiraIssueProject }[]
---@param query string
---@return table[]
local function filter_projects(items, query)
	query = vim.trim(query):lower()
	return vim.tbl_filter(function(item)
		local project = item.value
		local name = project and project.name or ""
		local category = project and project.category and project.category.name or ""
		local text = string.format("%s %s %s", item.label, name, category):lower()
		return text:find(query, 1, true) ~= nil
	end, items)
end

---@param _ AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function create_issue(_, done)
	local function open_editor(project)
		if not project then
			notify.info("Create issue cancelled", { timeout = 1200, vim_notify = true })
			done(nil, nil)
			return
		end

		require("atlas.issues.providers.jira.ui.editor").open(project.key, function(result, err)
			done(result and { issue_key = result.key } or nil, err)
		end)
	end

	notify.loading("Loading projects...")
	return projects_api.get_projects({ maxResults = 50, total = math.huge, status = "live" }, function(groups, err)
		if err or not groups then
			err = err or "Failed to load projects"
			notify.error(err)
			done(nil, err)
			return
		end

		local projects = flatten_projects(groups)
		if #projects == 0 then
			notify.info("No Jira projects found")
			done(nil, nil)
			return
		end

		local project_ids = {}
		for _, project in ipairs(projects) do
			local project_id = tonumber(project.id)
			if project_id then
				table.insert(project_ids, project_id)
			end
		end

		issues_api.get_permissions_bulk({
			permissions = { "CREATE_ISSUES" },
			project_ids = project_ids,
		}, function(permission_map, perm_err)
			if perm_err or not permission_map then
				perm_err = perm_err or "Failed to load project permissions"
				notify.error(perm_err)
				done(nil, perm_err)
				return
			end

			local allowed_map = permission_map.CREATE_ISSUES or {}
			local allowed_projects = vim.tbl_filter(function(project)
				return allowed_map[tonumber(project.id)] == true
			end, projects)

			notify.clear()
			if #allowed_projects == 0 then
				notify.info("No Jira projects allow creating issues")
				done(nil, nil)
			elseif #allowed_projects == 1 then
				open_editor(allowed_projects[1])
			else
				picker.select({
					title = "Create Issue",
					items = allowed_projects,
					format_item = format_project,
					on_select = open_editor,
				})
			end
		end)
	end)
end

---@param issue Issue
---@param details JiraIssueDetails
---@return AtlasPickerPreview
local function format_preview(issue, details)
	local assignee = details.assignees[1]
	local status = "**Status:** " .. (details.status or "Unknown")
	local assignee_name = "**Assignee:** " .. (assignee and assignee.name or "Unassigned")
	local column = math.max(vim.fn.strdisplaywidth(status), vim.fn.strdisplaywidth(assignee_name)) + 4
	local lines = {
		status
			.. string.rep(" ", column - vim.fn.strdisplaywidth(status))
			.. "**Priority:** "
			.. (details.priority or "None"),
		assignee_name
			.. string.rep(" ", column - vim.fn.strdisplaywidth(assignee_name))
			.. "**Reporter:** "
			.. (details.reporter and details.reporter.name or "Unknown"),
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
	vim.list_extend(lines, vim.split(description ~= "" and description or "No description", "\n", { plain = true }))
	return {
		title = string.format("%s - %s", issue.key, issue.title),
		lines = lines,
	}
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
				preview_done(format_preview(issue, details))
			end)
		end,
		fetch = function(query, fetch_done)
			return issues_api.issue_picker(project, vim.trim(query), function(items, err)
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

		local projects = flatten_projects(groups)
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
					return icons.provider_icon("jira", "issues") .. " " .. item.label
				end
				return format_project(project)
			end,
			fetch = function(query, fetch_done)
				fetch_done(filter_projects(items, query), nil)
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

		local projects = flatten_projects(groups)
		if #projects == 0 then
			notify.info("No Jira projects found")
			done(nil, nil)
			return
		end
		picker.select({
			title = "Open Project",
			items = projects,
			format_item = format_project,
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

---@param issue Issue
---@return string|nil
local function issue_url(issue)
	local base_url = service.base_url():gsub("/$", "")
	if base_url == "" then
		return nil
	end
	return base_url .. "/browse/" .. issue.key
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function browse_issue(ctx, done)
	local issue = assert(ctx.issue)

	local url = issue_url(issue)
	if url == nil then
		notify.error("No URL found for issue")
		done(nil, "No URL found for issue")
		return
	end

	vim.ui.open(url)
	notify.success(string.format("Opened %s in browser", issue.key), { timeout = 1200 })
	done(nil, nil)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function copy_issue_url(ctx, done)
	local issue = assert(ctx.issue)

	local url = issue_url(issue)
	if url == nil then
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
		issues_api.set_subscription(issue_key, true, nil, finish)
		return
	end

	local function unsubscribe(account_id)
		issues_api.set_subscription(issue_key, false, account_id, finish)
	end

	local current = ctx.current_user
	if current and (current.id or "") ~= "" then
		unsubscribe(current.id)
		return
	end

	users_api.fetch_user(function(user, err)
		if err or not user or user.id == "" then
			finish(nil, err or "Failed to fetch Jira user")
			return
		end
		unsubscribe(user.id)
	end)
end

register({
	id = "transition",
	label = "Transition",
	icon = icons.get("transition", "actions"),
	is_available = has_issue_key,
	run = transition,
})
register({
	id = "assign",
	label = "Edit Assignee",
	icon = icons.get("edit", "actions"),
	is_available = has_issue_key,
	run = assign,
})
register({
	id = "reporter",
	label = "Edit Reporter",
	icon = icons.get("edit", "actions"),
	is_available = has_issue_key,
	run = reporter,
})
register({
	id = "edit_issue",
	label = "Edit Issue",
	icon = icons.get("edit", "actions"),
	is_available = has_issue_key,
	run = edit_issue,
})
register({
	id = "search",
	label = "Search Issue",
	icon = icons.get("search", "actions"),
	run = search_issue,
})
register({
	id = "open_project",
	label = "Open Project",
	icon = icons.get("search", "actions"),
	run = open_project,
})
register({
	id = "search_jql",
	label = "Search JQL",
	icon = icons.get("search", "actions"),
	run = search_jql,
})
register({
	id = "edit_search",
	label = "Edit Current Search",
	icon = icons.get("search", "actions"),
	run = function(_, done)
		require("atlas.issues.providers.jira.completion.search").edit(current_jql(), function(query)
			local view = issues_state.search_view()
			if view then
				---@cast view AtlasJiraViewConfig
				view.jql = query
				view.search = nil
				require("atlas.issues.ui.dashboard.controller").refresh_view()
			end
		end)
		done(nil, nil)
	end,
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
	icon = icons.get("notification", "actions"),
	is_available = toggle_subscription_available,
	run = toggle_subscription,
})
register({
	id = "create_issue",
	label = "Create Issue",
	icon = icons.get("create", "actions"),
	run = create_issue,
})
register({
	id = "delete_issue",
	label = "Delete Issue",
	icon = icons.get("delete", "actions"),
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
