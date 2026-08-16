local M = {}

local actions = require("atlas.issues.actions")
local icons = require("atlas.ui.shared.icons")
local picker = require("atlas.picker")
local statusline = require("atlas.ui.statusline")
local api = require("atlas.issues.providers.gitea.api").issues

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function has_issue(ctx)
	if type(ctx.issue) ~= "table" or tostring(ctx.issue.key or "") == "" then
		return false, "No issue selected"
	end
	return true, nil
end

---@param left any[]
---@param right any[]
---@return boolean
local function same_values(left, right)
	if #left ~= #right then
		return false
	end
	local first, second = {}, {}
	for _, value in ipairs(left) do
		table.insert(first, tostring(value))
	end
	for _, value in ipairs(right) do
		table.insert(second, tostring(value))
	end
	table.sort(first)
	table.sort(second)
	return table.concat(first, "\0") == table.concat(second, "\0")
end

---@param issue Issue
---@return string
local function issue_slug(issue)
	local raw = issue._raw or {}
	local slug = tostring(raw.project_path or "")
	if slug ~= "" then
		return slug
	end
	return (tostring(issue.key or ""):match("^([^/]+/[^/]+)#%d+$")) or ""
end

---@param ctx AtlasIssueActionContext
---@return string|nil
local function context_slug(ctx)
	local explicit = tostring(ctx.repo_slug or "")
	if explicit ~= "" then
		return explicit
	end
	if type(ctx.issue) == "table" then
		local slug = issue_slug(ctx.issue)
		if slug ~= "" then
			return slug
		end
	end
	local issues_state = require("atlas.issues.state")
	for _, view in ipairs({ issues_state.current_view or {}, issues_state.active_view or {} }) do
		---@cast view AtlasGiteaForgejoIssuesViewConfig
		local configured = vim.trim(tostring(view.repo or ""))
		if configured:match("^[^/%s]+/[^/%s]+$") then
			return configured
		end
	end

	local git = require("atlas.core.git")
	local root = git.repo_root(nil)
	local remote = root and git.remote_url(root, "origin") or nil
	local info = remote and git.parse_remote_url(remote) or nil
	return info and info.provider == "gitea" and info.slug or nil
end

---@return string[]
local function configured_repositories()
	local options = require("atlas.providers").options("gitea", "issues") or {}
	local result, seen = {}, {}
	local function add(value)
		local slug = type(value) == "table" and vim.trim(tostring(value.repo or "")) or ""
		if slug:match("^[^/%s]+/[^/%s]+$") and not seen[slug] then
			seen[slug] = true
			table.insert(result, slug)
		end
	end
	for _, view in ipairs(options.views or {}) do
		add(view)
	end
	for _, value in pairs(type(options.bookmarks) == "table" and options.bookmarks.items or {}) do
		add(value)
	end
	table.sort(result)
	return result
end

---@param ctx AtlasIssueActionContext
---@return string[]
local function create_repositories(ctx)
	local slug = context_slug(ctx)
	return slug and { slug } or configured_repositories()
end

---@param action_id string
---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function run_action(action_id, ctx, done)
	local action = M.find(action_id)
	if not action then
		done(nil, "Unknown action: " .. tostring(action_id))
		return
	end
	action.run(ctx, done)
end

---@param issue Issue
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function edit_assignees(issue, done)
	local slug = issue_slug(issue)
	statusline.notify("loading", "Loading assignees...")
	api.list_assignees(slug, function(users, err)
		if err or not users then
			done(nil, err or "Failed to load assignees")
			return
		end
		statusline.clear_notice()
		local selected, current_logins = {}, {}
		local by_login = {}
		for _, item in ipairs(users) do
			by_login[item.account_id] = item
		end
		for _, raw in ipairs((issue._raw or {}).assignees or {}) do
			local login = tostring(raw.login or "")
			if by_login[login] then
				table.insert(selected, by_login[login])
				table.insert(current_logins, login)
			end
		end
		picker.multi_select({
			items = users,
			selected = selected,
			key = function(item)
				return tostring(item.account_id or "")
			end,
			format_item = function(item)
				return string.format("%s %s (@%s)", icons.general("user"), item.display_name, item.account_id)
			end,
			title = "Assignees for " .. issue.key,
			on_done = function(values)
				local logins = {}
				for _, item in ipairs(values or {}) do
					table.insert(logins, item.account_id)
				end
				if same_values(logins, current_logins) then
					done(nil, nil)
					return
				end
				statusline.notify("loading", "Updating assignees...")
				api.update_assignees(issue.key, logins, function(ok, update_err)
					if not ok then
						done(nil, update_err or "Failed to update assignees")
						return
					end
					statusline.notify("success", "Assignees updated", 1200)
					done({ issue_key = issue.key }, nil)
				end)
			end,
		})
	end)
end

---@param issue Issue
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function edit_labels(issue, done)
	local slug = issue_slug(issue)
	statusline.notify("loading", "Loading labels...")
	api.list_labels(slug, function(labels, err)
		if err or not labels then
			done(nil, err or "Failed to load labels")
			return
		end
		statusline.clear_notice()
		local selected, current_ids, by_name = {}, {}, {}
		for _, item in ipairs(labels) do
			by_name[item.name] = item
		end
		for _, raw in ipairs((issue._raw or {}).labels or {}) do
			if by_name[raw.name] then
				table.insert(selected, by_name[raw.name])
				table.insert(current_ids, by_name[raw.name].id or by_name[raw.name].name)
			end
		end
		picker.multi_select({
			items = labels,
			selected = selected,
			key = function(item)
				return tostring(item.id or item.name or "")
			end,
			format_item = function(item)
				return tostring(item.name or "")
			end,
			title = "Labels for " .. issue.key,
			on_done = function(values)
				local ids = {}
				for _, item in ipairs(values or {}) do
					table.insert(ids, item.id or item.name)
				end
				if same_values(ids, current_ids) then
					done(nil, nil)
					return
				end
				statusline.notify("loading", "Updating labels...")
				api.update_labels(issue.key, ids, function(ok, update_err)
					if not ok then
						done(nil, update_err or "Failed to update labels")
						return
					end
					statusline.notify("success", "Labels updated", 1200)
					done({ issue_key = issue.key }, nil)
				end)
			end,
		})
	end)
end

---@param issue Issue
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function edit_milestone(issue, done)
	statusline.notify("loading", "Loading milestones...")
	api.list_milestones(issue_slug(issue), function(milestones, err)
		if err or not milestones then
			done(nil, err or "Failed to load milestones")
			return
		end
		statusline.clear_notice()
		local choices = { { id = nil, title = "None" } }
		vim.list_extend(choices, milestones)
		picker.select({
			title = "Milestone for " .. issue.key,
			items = choices,
			format_item = function(item)
				return item.title
			end,
			on_select = function(choice)
				if not choice then
					done(nil, nil)
					return
				end
				local current = type((issue._raw or {}).milestone) == "table" and (issue._raw or {}).milestone.id or nil
				if tostring(choice.id or "") == tostring(current or "") then
					done(nil, nil)
					return
				end
				statusline.notify("loading", "Updating milestone...")
				api.update_milestone(issue.key, choice.id, function(ok, update_err)
					if not ok then
						done(nil, update_err or "Failed to update milestone")
						return
					end
					statusline.notify("success", choice.id and "Milestone updated" or "Milestone removed", 1200)
					done({ issue_key = issue.key }, nil)
				end)
			end,
		})
	end)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function toggle_subscription(ctx, done)
	local issue = assert(ctx.issue)
	local login = type(ctx.current_user) == "table" and vim.trim(tostring(ctx.current_user.account_id or "")) or ""
	local function with_login(callback)
		if login ~= "" then
			callback(login)
			return
		end
		api.fetch_user(function(user, err)
			local fetched = type(user) == "table" and vim.trim(tostring(user.account_id or "")) or ""
			if err or fetched == "" then
				done(nil, err or "Could not determine current user")
				return
			end
			callback(fetched)
		end)
	end
	local function update(subscribed)
		with_login(function(user_login)
			local next_state = not subscribed
			statusline.notify("loading", next_state and "Subscribing..." or "Unsubscribing...")
			api.set_subscription(issue.key, user_login, next_state, function(ok, err)
				if not ok then
					done(nil, err or "Failed to update subscription")
					return
				end
				issue.is_subscribed = next_state
				statusline.notify("success", next_state and "Subscribed" or "Unsubscribed", 1200)
				done({ issue_key = issue.key }, nil)
			end)
		end)
	end

	if type(issue.is_subscribed) == "boolean" then
		update(issue.is_subscribed)
		return
	end
	api.check_subscription(issue.key, function(subscribed, err)
		if err or type(subscribed) ~= "boolean" then
			done(nil, err or "Could not read subscription")
			return
		end
		update(subscribed)
	end)
end

---@param ctx AtlasIssueActionContext
---@param locked boolean
---@param reason string|nil
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function set_locked(ctx, locked, reason, done)
	local issue = assert(ctx.issue)
	statusline.notify("loading", (locked and "Locking " or "Unlocking ") .. issue.key .. "...")
	api.set_locked(issue.key, locked, reason, function(ok, err)
		if not ok then
			done(nil, err or (locked and "Failed to lock issue" or "Failed to unlock issue"))
			return
		end
		issue._raw = issue._raw or {}
		issue._raw.is_locked = locked
		statusline.notify("success", (locked and "Locked " or "Unlocked ") .. issue.key, 1200)
		done({ issue_key = issue.key }, nil)
	end)
end

---@type AtlasIssueAction[]
local ACTIONS = {}
M.items = ACTIONS

---@param action AtlasIssueAction
local function register(action)
	table.insert(ACTIONS, action)
end

register({
	id = "close",
	label = "Close Issue",
	is_available = function(ctx)
		local ok, err = has_issue(ctx)
		if not ok then
			return false, err
		end
		return ctx.issue.status_id ~= "closed", "Issue is already closed"
	end,
	run = function(ctx, done)
		statusline.notify("loading", "Closing " .. ctx.issue.key .. "...")
		api.set_state(ctx.issue.key, "closed", function(ok, err)
			if not ok then
				done(nil, err or "Failed to close issue")
				return
			end
			statusline.notify("success", "Closed " .. ctx.issue.key, 1200)
			done({ issue_key = ctx.issue.key }, nil)
		end)
	end,
})

register({
	id = "reopen",
	label = "Reopen Issue",
	is_available = function(ctx)
		local ok, err = has_issue(ctx)
		if not ok then
			return false, err
		end
		return ctx.issue.status_id == "closed", "Issue is not closed"
	end,
	run = function(ctx, done)
		statusline.notify("loading", "Reopening " .. ctx.issue.key .. "...")
		api.set_state(ctx.issue.key, "open", function(ok, err)
			if not ok then
				done(nil, err or "Failed to reopen issue")
				return
			end
			statusline.notify("success", "Reopened " .. ctx.issue.key, 1200)
			done({ issue_key = ctx.issue.key }, nil)
		end)
	end,
})

register({
	id = "transition",
	label = "Transition Issue",
	hidden = true,
	is_available = has_issue,
	run = function(ctx, done)
		local action = ctx.issue.status_id == "closed" and "reopen" or "close"
		local verb = action == "reopen" and "Reopen" or "Close"
		vim.ui.input({ prompt = string.format("%s issue %s? [y/N]: ", verb, ctx.issue.key) }, function(input)
			if vim.trim(tostring(input or "")):lower() ~= "y" then
				done(nil, nil)
				return
			end
			run_action(action, ctx, done)
		end)
	end,
})

register({
	id = "pin",
	label = "Pin Issue",
	is_available = function(ctx)
		local ok, err = has_issue(ctx)
		if not ok then
			return false, err
		end
		return ctx.issue.is_pinned ~= true, "Issue is already pinned"
	end,
	run = function(ctx, done)
		statusline.notify("loading", "Pinning " .. ctx.issue.key .. "...")
		api.set_pinned(ctx.issue.key, true, function(ok, err)
			if not ok then
				done(nil, err or "Failed to pin issue")
				return
			end
			ctx.issue.is_pinned = true
			statusline.notify("success", "Pinned " .. ctx.issue.key, 1200)
			done({ issue_key = ctx.issue.key }, nil)
		end)
	end,
})

register({
	id = "unpin",
	label = "Unpin Issue",
	is_available = function(ctx)
		local ok, err = has_issue(ctx)
		if not ok then
			return false, err
		end
		return ctx.issue.is_pinned == true, "Issue is not pinned"
	end,
	run = function(ctx, done)
		statusline.notify("loading", "Unpinning " .. ctx.issue.key .. "...")
		api.set_pinned(ctx.issue.key, false, function(ok, err)
			if not ok then
				done(nil, err or "Failed to unpin issue")
				return
			end
			ctx.issue.is_pinned = false
			statusline.notify("success", "Unpinned " .. ctx.issue.key, 1200)
			done({ issue_key = ctx.issue.key }, nil)
		end)
	end,
})

if api.supports_locking() then
	register({
		id = "lock_issue",
		label = "Lock Issue",
		is_available = function(ctx)
			local ok, err = has_issue(ctx)
			if not ok then
				return false, err
			end
			return (ctx.issue._raw or {}).is_locked ~= true, "Issue is already locked"
		end,
		run = function(ctx, done)
			vim.ui.input({ prompt = "Lock reason (optional): " }, function(reason)
				if reason == nil then
					done(nil, nil)
					return
				end
				set_locked(ctx, true, reason, done)
			end)
		end,
	})

	register({
		id = "unlock_issue",
		label = "Unlock Issue",
		is_available = function(ctx)
			local ok, err = has_issue(ctx)
			if not ok then
				return false, err
			end
			return (ctx.issue._raw or {}).is_locked == true, "Issue is not locked"
		end,
		run = function(ctx, done)
			set_locked(ctx, false, nil, done)
		end,
	})
end

register({
	id = "edit_issue",
	label = "Edit Issue",
	is_available = has_issue,
	run = function(ctx, done)
		require("atlas.issues.create.gitea.issue").open({
			repo_slug = issue_slug(ctx.issue),
			issue = ctx.issue,
			on_done = function(result, err)
				done(result and { issue_key = ctx.issue.key } or nil, err)
			end,
		})
	end,
})

register({
	id = "assign",
	label = "Edit Assignees",
	is_available = has_issue,
	run = function(ctx, done)
		edit_assignees(ctx.issue, done)
	end,
})

register({
	id = "labels",
	label = "Edit Labels",
	is_available = has_issue,
	run = function(ctx, done)
		edit_labels(ctx.issue, done)
	end,
})

register({
	id = "milestone",
	label = "Edit Milestone",
	is_available = has_issue,
	run = function(ctx, done)
		edit_milestone(ctx.issue, done)
	end,
})

register({
	id = "toggle_subscription",
	label = "Toggle Subscription",
	is_available = has_issue,
	run = function(ctx, done)
		toggle_subscription(ctx, done)
	end,
})

register({
	id = "delete_issue",
	label = "Delete Issue",
	is_available = has_issue,
	run = function(ctx, done)
		vim.ui.input({ prompt = string.format("Delete issue %s? [y/N]: ", ctx.issue.key) }, function(input)
			if vim.trim(tostring(input or "")):lower() ~= "y" then
				done(nil, nil)
				return
			end
			statusline.notify("loading", "Deleting " .. ctx.issue.key .. "...")
			api.delete(ctx.issue.key, function(ok, err)
				if not ok then
					done(nil, err or "Failed to delete issue")
					return
				end
				statusline.notify("success", "Deleted " .. ctx.issue.key, 1200)
				done({ issue_key = ctx.issue.key, removed = true }, nil)
			end)
		end)
	end,
})

register({
	id = "create_issue",
	label = "Create Issue",
	is_available = function(ctx)
		return #create_repositories(ctx) > 0, "Could not determine repository"
	end,
	run = function(ctx, done)
		local repositories = create_repositories(ctx)
		local function open(slug)
			require("atlas.issues.create.gitea.issue").open({
				repo_slug = slug,
				on_done = function(result, err)
					done(result and { issue_key = result.key } or nil, err)
				end,
			})
		end
		if #repositories == 1 then
			open(repositories[1])
			return
		end
		picker.select({
			title = "Create issue in:",
			items = repositories,
			on_select = function(slug)
				if slug then
					open(slug)
				else
					done(nil, nil)
				end
			end,
		})
	end,
})

register({
	id = "search",
	label = "Search Issues",
	run = function(_, done)
		require("atlas.issues.providers.gitea.completion.search").open()
		done(nil, nil)
	end,
})

register(actions.manage_templates)
register(actions.browse_issue)
register(actions.copy_issue_key)
register(actions.copy_issue_url)

---@param id AtlasGiteaForgejoIssueActionId
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
