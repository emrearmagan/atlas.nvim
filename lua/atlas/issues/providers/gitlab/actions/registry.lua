local M = {}

local actions = require("atlas.issues.actions")
local icons = require("atlas.ui.shared.icons")
local picker = require("atlas.ui.picker")
local notify = require("atlas.core.notify")
local request_scope = require("atlas.core.requests")
local issues_api = require("atlas.issues.providers.gitlab.api.issues")
local users_api = require("atlas.issues.providers.gitlab.api.users")
local labels_api = require("atlas.issues.providers.gitlab.api.labels")
local service = require("atlas.providers.gitlab.client")

---@param ctx AtlasIssueActionContext
---@return boolean
local function has_issue(ctx)
	local issue = ctx.issue
	return issue ~= nil and tostring(issue.key or "") ~= ""
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
local function close_available(ctx)
	if not has_issue(ctx) then
		return false, "No issue selected"
	end
	return assert(ctx.issue).status_id ~= "closed", "Issue is already closed"
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function close(ctx, done)
	local issue = assert(ctx.issue)
	local key = tostring(issue.key or "")
	notify.loading(string.format("Closing %s...", key))
	issues_api.set_state(key, "close", function(ok, err)
		if not ok then
			notify.error(err or "Close failed")
			done(nil, err or "Close failed")
			return
		end
		notify.success(string.format("Closed %s", key), { timeout = 1200 })
		done({ issue_key = key }, nil)
	end)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function reopen_available(ctx)
	if not has_issue(ctx) then
		return false, "No issue selected"
	end
	return assert(ctx.issue).status_id == "closed", "Issue is not closed"
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function reopen(ctx, done)
	local issue = assert(ctx.issue)
	local key = tostring(issue.key or "")
	notify.loading(string.format("Reopening %s...", key))
	issues_api.set_state(key, "reopen", function(ok, err)
		if not ok then
			notify.error(err or "Reopen failed")
			done(nil, err or "Reopen failed")
			return
		end
		notify.success(string.format("Reopened %s", key), { timeout = 1200 })
		done({ issue_key = key }, nil)
	end)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function transition(ctx, done)
	local issue = assert(ctx.issue)
	local key = tostring(issue.key or "")
	local target = issue.status_id == "closed" and "reopen" or "close"
	local label = target == "close" and "Closing" or "Reopening"
	notify.loading(string.format("%s %s...", label, key))
	issues_api.set_state(key, target, function(ok, err)
		if not ok then
			notify.error(err or (label .. " failed"))
			done(nil, err or (label .. " failed"))
			return
		end
		local msg = target == "close" and "Closed" or "Reopened"
		notify.success(string.format("%s %s", msg, key), { timeout = 1200 })
		done({ issue_key = key }, nil)
	end)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function assign(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue GitLabIssue
	local key = tostring(issue.key or "")
	local path = issue.project_path
	if path == "" then
		local err = "Could not determine project path"
		notify.error(err)
		done(nil, err)
		return
	end

	---@param current_assignees IssueUser[]
	---@param members IssueUser[]
	local function open_picker(current_assignees, members)
		notify.clear()

		if #members == 0 then
			local message = "No assignable members"
			notify.warn(message)
			done(nil, message)
			return
		end

		local original = {}
		local original_set = {}
		for _, assignee in ipairs(current_assignees) do
			local id = tonumber(assignee.id)
			if id then
				table.insert(original, assignee)
				original_set[id] = true
			end
		end

		picker.multi_select({
			items = members,
			selected = vim.deepcopy(original),
			key = function(item)
				return tostring(item.id or item.account_id or "")
			end,
			format_item = function(item)
				return string.format(
					"%s %s (@%s)",
					icons.general("user"),
					item.display_name or item.account_id or item.name or item.username,
					item.account_id or item.username
				)
			end,
			title = string.format("Assignees for %s", key),
			on_done = function(selected)
				local final_ids = {}
				local final_set = {}
				for _, it in ipairs(selected) do
					local id = tonumber(it.id)
					if id then
						table.insert(final_ids, id)
						final_set[id] = true
					end
				end

				local changed = false
				if #final_ids ~= #original then
					changed = true
				else
					for id, _ in pairs(original_set) do
						if not final_set[id] then
							changed = true
							break
						end
					end
				end

				if not changed then
					done(nil, nil)
					return
				end

				notify.loading(string.format("Updating assignees on %s...", key))
				issues_api.set_assignee_ids(key, final_ids, function(ok, set_err)
					if not ok then
						notify.error(set_err or "Failed")
						done(nil, set_err or "Failed")
						return
					end
					local msg = string.format("%d assignee(s)", #final_ids)
					notify.success(msg, { timeout = 1200 })
					done({ issue_key = key }, nil)
				end)
			end,
		})
	end

	notify.loading("Loading assignees...")
	local requests = request_scope.new()
	requests.all({
		assignees = function(next)
			return issues_api.get_assignees(key, next)
		end,
		members = function(next)
			return users_api.list_members(path, "", next)
		end,
	}, function(values, errors)
		local err = errors.assignees or errors.members
		if err then
			local message = tostring(err)
			notify.error(message)
			done(nil, message)
			return
		end
		open_picker(values.assignees, values.members)
	end)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function labels(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue GitLabIssue
	local key = tostring(issue.key or "")
	local path = issue.project_path
	if path == "" then
		local err = "Could not determine project path"
		notify.error(err)
		done(nil, err)
		return
	end

	---@param current_labels IssueLabel[]
	---@param all_labels IssueLabel[]
	local function open_picker(current_labels, all_labels)
		notify.clear()
		if #all_labels == 0 then
			local message = "No labels available"
			notify.warn(message)
			done(nil, message)
			return
		end

		local original = {}
		local original_set = {}
		for _, label in ipairs(current_labels) do
			local name = tostring(label.name or "")
			if name ~= "" then
				table.insert(original, { name = name, color = label.color })
				original_set[name] = true
			end
		end

		picker.multi_select({
			items = all_labels,
			selected = vim.deepcopy(original),
			key = function(item)
				return tostring(item.name or "")
			end,
			format_item = function(item)
				return tostring(item.name or "")
			end,
			title = string.format("Labels for %s", key),
			on_done = function(selected)
				local selected_set = {}
				for _, it in ipairs(selected) do
					selected_set[it.name] = true
				end
				local adds, removes = {}, {}
				for name, _ in pairs(selected_set) do
					if not original_set[name] then
						table.insert(adds, name)
					end
				end
				for name, _ in pairs(original_set) do
					if not selected_set[name] then
						table.insert(removes, name)
					end
				end
				if #adds == 0 and #removes == 0 then
					done(nil, nil)
					return
				end

				notify.loading(string.format("Updating labels on %s...", key))
				issues_api.update_labels(key, { add = adds, remove = removes }, function(ok, set_err)
					if not ok then
						notify.error(set_err or "Failed")
						done(nil, set_err or "Failed")
						return
					end
					local msg = string.format("+%d / -%d label(s)", #adds, #removes)
					notify.success(msg, { timeout = 1200 })
					done({ issue_key = key }, nil)
				end)
			end,
		})
	end

	notify.loading("Loading labels...")
	issues_api.fetch_issue_labels(key, function(current_labels, current_err)
		if current_err or current_labels == nil then
			local message = current_err or "Failed to load issue labels"
			notify.error(message)
			done(nil, message)
			return
		end

		labels_api.list(path, function(all_labels, labels_err)
			if labels_err or all_labels == nil then
				local message = labels_err or "Failed to load labels"
				notify.error(message)
				done(nil, message)
				return
			end
			open_picker(current_labels, all_labels)
		end)
	end)
end

---@param opts {
--- title: string,
--- include_all: boolean,
--- on_select: fun(project: string),
--- on_cancel: fun(),
---}
local function select_project(opts)
	local initial_items = opts.include_all and { { id = "all", label = "All projects", project = "" } } or {}
	picker.search({
		title = opts.title,
		initial_items = initial_items,
		fetch_on_open = false,
		format_item = function(item)
			return item.label
		end,
		fetch = function(query, fetch_done)
			query = vim.trim(query)
			if query == "" then
				fetch_done(initial_items, nil)
				return
			end

			local endpoint = string.format(
				"/projects?search=%s&per_page=20&order_by=last_activity_at&with_issues_enabled=true",
				service.url_encode(query)
			)
			return service.request("GET", endpoint, nil, function(result, err)
				if err then
					fetch_done(nil, tostring(err))
					return
				end

				local items = {}
				for _, project in ipairs(result) do
					local path = project.path_with_namespace
					table.insert(items, { id = path, label = path, project = path })
				end
				fetch_done(items, nil)
			end, {
				action = "Search projects",
				query = query,
			})
		end,
		on_select = function(item)
			opts.on_select(item.project)
		end,
		on_cancel = opts.on_cancel,
	})
end

---@param project string
---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function search_issues(project, ctx, done)
	picker.search({
		title = project ~= "" and "Search " .. project .. " Issues" or "Search GitLab Issues",
		fetch_on_open = false,
		format_item = function(item)
			return item.label
		end,
		preview_item = function(item, preview_done)
			local issue = item.value
			return issues_api.fetch_issue(issue, nil, function(details, err)
				if err or details == nil then
					preview_done({ title = issue.key, lines = { err or "Failed to load issue" } })
					return
				end
				local assignees = vim.tbl_map(function(user)
					return "@" .. user.account_id
				end, details.assignees)
				local label_names = vim.tbl_map(function(label)
					return label.name
				end, details.labels)
				local author = issue.reporter and issue.reporter.display_name or "Unknown"
				local lines = {
					"**Status:** " .. (issue.status or "Open"),
					"**Author:** " .. author,
					"**Assignees:** " .. (#assignees > 0 and table.concat(assignees, ", ") or "Unassigned"),
				}
				if #label_names > 0 then
					table.insert(lines, "**Labels:** " .. table.concat(label_names, ", "))
				end
				if details.milestone then
					table.insert(lines, "**Milestone:** " .. details.milestone.title)
				end
				vim.list_extend(lines, { "", "## Description", "" })
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
			query = vim.trim(query)
			if query == "" then
				fetch_done({}, nil)
				return
			end

			---@type AtlasGitLabIssuesViewConfig
			local view = { name = "Search", scope = "all", state = "all", search = query }
			if project ~= "" then
				view.project = project
			end
			return issues_api.list_issues(view, { force_refresh = false, pagelen = 30 }, function(page, err)
				if err then
					fetch_done(nil, err or "Search failed")
					return
				end
				local items = {}
				for _, issue in ipairs(page.items) do
					table.insert(items, {
						id = issue.key,
						label = string.format("%s - %s", issue.key, issue.title),
						value = issue,
					})
				end
				fetch_done(items, nil)
			end)
		end,
		on_select = function(item)
			require("atlas.issues.ui.detail").open(item.value, { provider = ctx.provider })
			done(nil, nil)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function search(ctx, done)
	select_project({
		title = "Search Issues - Project",
		include_all = true,
		on_select = function(project)
			search_issues(project, ctx, done)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param _ AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function open_project(_, done)
	select_project({
		title = "Open Project",
		include_all = false,
		on_select = function(project)
			require("atlas").open("issues", "gitlab", {
				initial_view = {
					name = "Search",
					layout = "compact",
					project = project,
					scope = "all",
					state = "all",
				},
			})
			done(nil, nil)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function create_issue(ctx, done)
	local resolved = ctx.project_path or ""
	if resolved == "" and has_issue(ctx) then
		local issue = assert(ctx.issue)
		---@cast issue GitLabIssue
		resolved = issue.project_path
	end
	if resolved == "" then
		local git = require("atlas.core.git")
		local root = git.repo_root(nil)
		if root then
			local remote = git.remote_url(root, "origin")
			local info = remote and git.parse_remote_url(remote) or nil
			if info and info.provider == "gitlab" and info.repo_full_name and info.repo_full_name ~= "" then
				resolved = info.repo_full_name
			end
		end
	end

	local function open_editor(path)
		local create_issue_ui = require("atlas.issues.create.gitlab.issue")
		create_issue_ui.open({
			project_path = path,
			on_done = function(result, err)
				if err then
					done(nil, tostring(err))
					return
				end
				if result == nil then
					done(nil, nil)
					return
				end
				done({ issue_key = result.key }, nil)
			end,
		})
	end

	if resolved ~= "" then
		open_editor(resolved)
		return
	end

	vim.ui.input({ prompt = "Project (group/project): " }, function(input)
		if input == nil then
			done(nil, nil)
			return
		end
		local path = vim.trim(tostring(input))
		if path == "" then
			done(nil, nil)
			return
		end
		open_editor(path)
	end)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function toggle_subscription_available(ctx)
	if not has_issue(ctx) then
		return false, "No issue selected"
	end
	local issue = assert(ctx.issue)
	---@cast issue GitLabIssue
	if issue.project_path == "" then
		return false, "Invalid issue identifier"
	end
	return true, nil
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function toggle_subscription(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue GitLabIssue
	local action = issue.is_subscribed == true and "unsubscribe" or "subscribe"
	local endpoint =
		string.format("/projects/%s/issues/%d/%s", service.url_encode(issue.project_path), issue.iid, action)
	notify.loading(issue.is_subscribed and "Unsubscribing..." or "Subscribing...")
	service.request("POST", endpoint, nil, function(result, err)
		if err then
			notify.error(tostring(err))
			done(nil, tostring(err))
			return
		end
		local subscribed = type(result) == "table" and result.subscribed
		if type(subscribed) ~= "boolean" then
			subscribed = action == "subscribe"
		end
		issue.is_subscribed = subscribed == true
		notify.success(issue.is_subscribed and "Subscribed" or "Unsubscribed", { timeout = 1200 })
		done({ issue_key = issue.key }, nil)
	end, {
		action = action == "subscribe" and "Subscribe to issue" or "Unsubscribe from issue",
		project_path = issue.project_path,
		iid = issue.iid,
	})
end

register({
	id = "close",
	label = "Close Issue",
	icon = icons.action("close"),
	is_available = close_available,
	run = close,
})
register({
	id = "reopen",
	label = "Reopen Issue",
	icon = icons.action("reopen"),
	is_available = reopen_available,
	run = reopen,
})
register({
	id = "transition",
	label = "Toggle Open/Closed",
	icon = icons.action("transition"),
	is_available = has_issue,
	run = transition,
})
register({
	id = "assign",
	label = "Edit Assignees",
	icon = icons.action("user"),
	is_available = has_issue,
	run = assign,
})
register({ id = "labels", label = "Edit Labels", icon = icons.action("label"), is_available = has_issue, run = labels })
register({ id = "search", label = "Search Issues", icon = icons.action("search"), run = search })
register({ id = "open_project", label = "Open Project", icon = icons.action("search"), run = open_project })
register(actions.manage_templates)
register(actions.browse_issue)
register(actions.copy_issue_key)
register(actions.copy_issue_url)
register({
	id = "toggle_subscription",
	label = "Toggle subscription",
	icon = icons.action("notification"),
	is_available = toggle_subscription_available,
	run = toggle_subscription,
})
register({ id = "create_issue", label = "Create Issue", icon = icons.action("create"), run = create_issue })

---@param id AtlasGitLabIssueActionId
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
