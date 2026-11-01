local M = {}

local actions = require("atlas.issues.actions")
local icons = require("atlas.ui.shared.icons")
local picker = require("atlas.ui.picker")
local notify = require("atlas.core.notify")
local config = require("atlas.config")

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function has_issue(ctx)
	if not ctx.issue then
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

---@param service ForgeService
---@param api ForgeIssuesApi
---@return AtlasIssueAction[]
function M.new(service, api)
	local provider_id = service.id
	local provider_name = service.name
	local editor = require("atlas.issues.providers.forge.ui.editor").new(service, api)
	local users_api = service.users
	local search = require("atlas.issues.providers.forge.actions.search").new(service, api)
	local set_locked_api = api.set_locked

	---@param issue Issue
	---@return string
	local function issue_slug(issue)
		---@cast issue GiteaIssue|ForgejoIssue
		return issue.repo_full_name
	end

	---@param ctx AtlasIssueActionContext
	---@return string|nil
	local function context_slug(ctx)
		local explicit = ctx.repo_slug or ""
		if explicit ~= "" then
			return explicit
		end
		if ctx.issue then
			local slug = issue_slug(ctx.issue)
			if slug ~= "" then
				return slug
			end
		end
		local issues_state = require("atlas.issues.state")
		if issues_state.provider and issues_state.provider.id == provider_id then
			---@param view AtlasGiteaIssuesViewConfig|AtlasForgejoIssuesViewConfig|nil
			local function view_repo(view)
				if view == nil then
					return nil
				end
				local configured = vim.trim(view.repo or "")
				if configured:match("^[^/%s]+/[^/%s]+$") then
					return configured
				end
			end
			local view = issues_state.search_view()
			---@cast view AtlasGiteaIssuesViewConfig|AtlasForgejoIssuesViewConfig|nil
			local configured = view_repo(view)
			if configured then
				return configured
			end
		end
	end

	---@param issue GiteaIssue|ForgejoIssue
	---@param done fun(result: IssuesActionResult|nil, err: string|nil)
	---@param run fun(details: GiteaIssueDetails|ForgejoIssueDetails)
	local function with_details(issue, done, run)
		api.get(issue, { force_refresh = true }, function(details, err)
			if err or not details then
				err = err or ("Failed to load " .. provider_name .. " issue")
				notify.error(err)
				done(nil, err)
				return
			end
			---@cast details GiteaIssueDetails|ForgejoIssueDetails
			run(details)
		end)
	end

	---@param ctx AtlasIssueActionContext
	---@return string[]
	local function create_repositories(ctx)
		local slug = context_slug(ctx)
		if slug then
			return { slug }
		end

		---@type AtlasGiteaIssuesConfig|AtlasForgejoIssuesConfig
		local configured = config.domain_options(provider_id, "issues") or {}
		local result, seen = {}, {}
		---@param value string|AtlasGiteaIssuesSearchConfig|AtlasForgejoIssuesSearchConfig
		local function add(value)
			if type(value) ~= "table" then
				return
			end
			local repo = vim.trim(value.repo or "")
			if repo:match("^[^/%s]+/[^/%s]+$") and not seen[repo] then
				seen[repo] = true
				table.insert(result, repo)
			end
		end
		for _, view in ipairs(configured.views or {}) do
			add(view)
		end
		for _, value in pairs((configured.bookmarks or {}).items or {}) do
			add(value)
		end
		table.sort(result)
		return result
	end

	---@param issue Issue
	---@param done fun(result: IssuesActionResult|nil, err: string|nil)
	local function edit_assignees(issue, done)
		---@cast issue GiteaIssue|ForgejoIssue
		notify.loading("Loading assignees...")
		with_details(issue, done, function(details)
			users_api.get_assignable_users(issue_slug(issue), nil, function(users, err)
				if err then
					notify.error(err)
					done(nil, err)
					return
				end
				notify.clear()
				local selected, current_logins = {}, {}
				local by_login = {}
				for _, item in ipairs(users) do
					by_login[item.username] = item
				end
				for _, assignee in ipairs(details.assignees) do
					local login = assignee.username
					if by_login[login] then
						table.insert(selected, by_login[login])
						table.insert(current_logins, login)
					end
				end
				picker.multi_select({
					items = users,
					selected = selected,
					key = function(item)
						return item.username
					end,
					format_item = function(item)
						return string.format("%s %s (@%s)", icons.get("user"), item.name, item.username)
					end,
					title = "Assignees for " .. issue.key,
					on_done = function(values)
						local logins = {}
						for _, item in ipairs(values) do
							table.insert(logins, item.username)
						end
						if same_values(logins, current_logins) then
							done(nil, nil)
							return
						end
						notify.loading("Updating assignees...")
						api.update_assignees(issue, logins, function(ok, update_err)
							if not ok then
								notify.error(update_err)
								done(nil, update_err)
								return
							end
							notify.success("Assignees updated", { timeout = 1200 })
							done({ issue_key = issue.key }, nil)
						end)
					end,
				})
			end)
		end)
	end

	---@param issue Issue
	---@param done fun(result: IssuesActionResult|nil, err: string|nil)
	local function edit_labels(issue, done)
		---@cast issue GiteaIssue|ForgejoIssue
		notify.loading("Loading labels...")
		with_details(issue, done, function(details)
			api.list_labels(issue_slug(issue), function(labels, err)
				if err then
					notify.error(err)
					done(nil, err)
					return
				end
				notify.clear()
				local selected, current_ids, by_name = {}, {}, {}
				for _, item in ipairs(labels) do
					by_name[item.name] = item
				end
				for _, label in ipairs(details.labels) do
					if by_name[label.name] then
						table.insert(selected, by_name[label.name])
						table.insert(current_ids, by_name[label.name].id)
					end
				end
				picker.multi_select({
					items = labels,
					selected = selected,
					key = function(item)
						return tostring(item.id)
					end,
					format_item = function(item)
						return item.name
					end,
					title = "Labels for " .. issue.key,
					on_done = function(values)
						local ids = {}
						for _, item in ipairs(values) do
							table.insert(ids, item.id)
						end
						if same_values(ids, current_ids) then
							done(nil, nil)
							return
						end
						notify.loading("Updating labels...")
						api.update_labels(issue, ids, function(ok, update_err)
							if not ok then
								notify.error(update_err)
								done(nil, update_err)
								return
							end
							notify.success("Labels updated", { timeout = 1200 })
							done({ issue_key = issue.key }, nil)
						end)
					end,
				})
			end)
		end)
	end

	---@param issue Issue
	---@param done fun(result: IssuesActionResult|nil, err: string|nil)
	local function edit_milestone(issue, done)
		---@cast issue GiteaIssue|ForgejoIssue
		notify.loading("Loading milestones...")
		with_details(issue, done, function(details)
			api.list_milestones(issue_slug(issue), function(milestones, err)
				if err then
					notify.error(err)
					done(nil, err)
					return
				end
				notify.clear()
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
						local current = details.milestone and details.milestone.id or nil
						if choice.id == current then
							done(nil, nil)
							return
						end
						notify.loading("Updating milestone...")
						api.update_milestone(issue, choice.id, function(ok, update_err)
							if not ok then
								notify.error(update_err)
								done(nil, update_err)
								return
							end
							notify.success(choice.id and "Milestone updated" or "Milestone removed", { timeout = 1200 })
							done({ issue_key = issue.key }, nil)
						end)
					end,
				})
			end)
		end)
	end

	---@param ctx AtlasIssueActionContext
	---@param done fun(result: IssuesActionResult|nil, err: string|nil)
	local function toggle_subscription(ctx, done)
		local issue = assert(ctx.issue)
		---@cast issue GiteaIssue|ForgejoIssue
		local login = ctx.current_user and ctx.current_user.username or nil
		local function update(subscribed, user_login)
			local next_state = not subscribed
			notify.loading(next_state and "Subscribing..." or "Unsubscribing...")
			api.set_subscription(issue, user_login, next_state, function(ok, err)
				if not ok then
					notify.error(err)
					done(nil, err)
					return
				end
				issue.is_subscribed = next_state
				notify.success(next_state and "Subscribed" or "Unsubscribed", { timeout = 1200 })
				done({ issue_key = issue.key }, nil)
			end)
		end
		local function resolve_login(subscribed)
			if login then
				update(subscribed, login)
				return
			end
			users_api.fetch_user(function(user, err)
				if err or not user then
					err = err or "Failed to resolve current user"
					notify.error(err)
					done(nil, err)
					return
				end
				update(subscribed, user.username)
			end)
		end

		if issue.is_subscribed ~= nil then
			resolve_login(issue.is_subscribed)
			return
		end
		api.check_subscription(issue, function(subscribed, err)
			if err then
				notify.error(err)
				done(nil, err)
				return
			end
			resolve_login(subscribed)
		end)
	end

	---@type AtlasIssueAction[]
	local ACTIONS = {}

	---@param action AtlasIssueAction
	local function register(action)
		table.insert(ACTIONS, action)
	end

	register({
		id = "close",
		label = "Close Issue",
		confirmation = true,
		icon = icons.get("close", "actions"),
		is_available = function(ctx)
			local ok, err = has_issue(ctx)
			if not ok then
				return false, err
			end
			return ctx.issue.status_id ~= "closed", "Issue is already closed"
		end,
		run = function(ctx, done)
			local issue = assert(ctx.issue)
			---@cast issue GiteaIssue|ForgejoIssue
			notify.loading("Closing " .. issue.key .. "...")
			api.set_state(issue, "closed", function(ok, err)
				if not ok then
					notify.error(err)
					done(nil, err)
					return
				end
				notify.success("Closed " .. issue.key, { timeout = 1200 })
				done({ issue_key = issue.key }, nil)
			end)
		end,
	})

	register({
		id = "reopen",
		label = "Reopen Issue",
		icon = icons.get("reopen", "actions"),
		is_available = function(ctx)
			local ok, err = has_issue(ctx)
			if not ok then
				return false, err
			end
			return ctx.issue.status_id == "closed", "Issue is not closed"
		end,
		run = function(ctx, done)
			local issue = assert(ctx.issue)
			---@cast issue GiteaIssue|ForgejoIssue
			notify.loading("Reopening " .. issue.key .. "...")
			api.set_state(issue, "open", function(ok, err)
				if not ok then
					notify.error(err)
					done(nil, err)
					return
				end
				notify.success("Reopened " .. issue.key, { timeout = 1200 })
				done({ issue_key = issue.key }, nil)
			end)
		end,
	})

	register({
		id = "transition",
		label = "Transition Issue",
		icon = icons.get("transition", "actions"),
		hidden = true,
		is_available = has_issue,
		run = function(ctx, done)
			local action = ctx.issue.status_id == "closed" and "reopen" or "close"
			return actions.run(action, ctx, done)
		end,
	})

	register({
		id = "pin",
		label = "Pin Issue",
		icon = icons.get("save", "actions"),
		is_available = function(ctx)
			local ok, err = has_issue(ctx)
			if not ok then
				return false, err
			end
			local issue = ctx.issue
			---@cast issue GiteaIssue|ForgejoIssue
			return issue.is_pinned ~= true, "Issue is already pinned"
		end,
		run = function(ctx, done)
			local issue = assert(ctx.issue)
			---@cast issue GiteaIssue|ForgejoIssue
			notify.loading("Pinning " .. issue.key .. "...")
			api.set_pinned(issue, true, function(ok, err)
				if not ok then
					notify.error(err)
					done(nil, err)
					return
				end
				issue.is_pinned = true
				notify.success("Pinned " .. issue.key, { timeout = 1200 })
				done({ issue_key = issue.key }, nil)
			end)
		end,
	})

	register({
		id = "unpin",
		label = "Unpin Issue",
		icon = icons.get("save", "actions"),
		is_available = function(ctx)
			local ok, err = has_issue(ctx)
			if not ok then
				return false, err
			end
			local issue = ctx.issue
			---@cast issue GiteaIssue|ForgejoIssue
			return issue.is_pinned == true, "Issue is not pinned"
		end,
		run = function(ctx, done)
			local issue = assert(ctx.issue)
			---@cast issue GiteaIssue|ForgejoIssue
			notify.loading("Unpinning " .. issue.key .. "...")
			api.set_pinned(issue, false, function(ok, err)
				if not ok then
					notify.error(err)
					done(nil, err)
					return
				end
				issue.is_pinned = false
				notify.success("Unpinned " .. issue.key, { timeout = 1200 })
				done({ issue_key = issue.key }, nil)
			end)
		end,
	})

	-- Gitea exposes issue locking; Forgejo simply leaves these actions out.
	if set_locked_api then
		---@param ctx AtlasIssueActionContext
		---@param locked boolean
		---@param reason string|nil
		---@param done fun(result: IssuesActionResult|nil, err: string|nil)
		local function set_locked(ctx, locked, reason, done)
			local issue = assert(ctx.issue)
			---@cast issue GiteaIssue
			notify.loading((locked and "Locking " or "Unlocking ") .. issue.key .. "...")
			set_locked_api(issue, locked, reason, function(ok, err)
				if not ok then
					notify.error(err)
					done(nil, err)
					return
				end
				issue.is_locked = locked
				notify.success((locked and "Locked " or "Unlocked ") .. issue.key, { timeout = 1200 })
				done({ issue_key = issue.key }, nil)
			end)
		end

		register({
			id = "lock_issue",
			label = "Lock Issue",
			icon = icons.get("close", "actions"),
			is_available = function(ctx)
				local ok, err = has_issue(ctx)
				if not ok then
					return false, err
				end
				local issue = ctx.issue
				---@cast issue GiteaIssue|ForgejoIssue
				return issue.is_locked ~= true, "Issue is already locked"
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
			icon = icons.get("reopen", "actions"),
			is_available = function(ctx)
				local ok, err = has_issue(ctx)
				if not ok then
					return false, err
				end
				local issue = ctx.issue
				---@cast issue GiteaIssue|ForgejoIssue
				return issue.is_locked == true, "Issue is not locked"
			end,
			run = function(ctx, done)
				set_locked(ctx, false, nil, done)
			end,
		})
	end

	register({
		id = "edit_issue",
		label = "Edit Issue",
		icon = icons.get("edit", "actions"),
		is_available = has_issue,
		run = function(ctx, done)
			local issue = assert(ctx.issue)
			return editor.edit(issue, function(result, err)
				done(result and { issue_key = issue.key } or nil, err)
			end)
		end,
	})

	register({
		id = "assign",
		label = "Edit Assignees",
		icon = icons.get("user", "actions"),
		is_available = has_issue,
		run = function(ctx, done)
			edit_assignees(assert(ctx.issue), done)
		end,
	})

	register({
		id = "labels",
		label = "Edit Labels",
		icon = icons.get("label", "actions"),
		is_available = has_issue,
		run = function(ctx, done)
			edit_labels(assert(ctx.issue), done)
		end,
	})

	register({
		id = "milestone",
		label = "Edit Milestone",
		icon = icons.get("label", "actions"),
		is_available = has_issue,
		run = function(ctx, done)
			edit_milestone(assert(ctx.issue), done)
		end,
	})

	register({
		id = "toggle_subscription",
		label = "Toggle Subscription",
		icon = icons.get("notification", "actions"),
		is_available = has_issue,
		run = function(ctx, done)
			toggle_subscription(ctx, done)
		end,
	})

	register({
		id = "delete_issue",
		label = "Delete Issue",
		icon = icons.get("delete", "actions"),
		confirmation = true,
		is_available = has_issue,
		run = function(ctx, done)
			local issue = assert(ctx.issue)
			notify.loading("Deleting " .. issue.key .. "...")
			return api.delete(issue, function(ok, err)
				if not ok then
					notify.error(err)
					done(nil, err)
					return
				end
				notify.success("Deleted " .. issue.key, { timeout = 1200 })
				done({ issue_key = issue.key, removed = true }, nil)
			end)
		end,
	})

	register({
		id = "create_issue",
		label = "Create Issue",
		icon = icons.get("create", "actions"),
		run = function(ctx, done)
			local function open(slug)
				editor.open(slug, function(result, err)
					done(result and { issue_key = result.key } or nil, err)
				end)
			end
			local slug = context_slug(ctx)
			if slug then
				open(slug)
				return
			end
			return require("atlas.core.git").local_repository(nil, function(target, err)
				if target and target.provider == provider_id then
					open(target.repo_full_name)
					return
				end
				local repositories = create_repositories(ctx)
				if #repositories == 0 then
					local message = err or "Could not determine " .. provider_name .. " repository"
					notify.error(message)
					done(nil, message)
				elseif #repositories == 1 then
					open(repositories[1])
				else
					picker.select({
						title = "Create issue in:",
						items = repositories,
						on_select = function(selected)
							if selected then
								open(selected)
							else
								done(nil, nil)
							end
						end,
					})
				end
			end)
		end,
	})

	register({
		id = "search",
		label = "Search Issues",
		icon = icons.get("search", "actions"),
		run = search.search,
	})
	register({
		id = "edit_search",
		label = "Edit search",
		icon = icons.get("search", "actions"),
		is_available = search.can_edit,
		run = search.edit,
	})
	register({ id = "open_repo", label = "Open Repo", icon = icons.get("search", "actions"), run = search.open_repo })

	register(actions.browse_repository)
	register({
		id = "browse_repositories",
		label = "Browse Repository",
		icon = icons.get("overview"),
		run = search.browse_repositories,
	})
	register(actions.manage_templates)
	register(actions.browse_issue)
	register(actions.copy_issue_key)
	register(actions.copy_issue_url)

	return ACTIONS
end

return M
