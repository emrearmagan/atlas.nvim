local M = {}

local actions = require("atlas.issues.actions")
local icons = require("atlas.ui.shared.icons")
local picker = require("atlas.picker")
local statusline = require("atlas.ui.statusline")
local cli = require("atlas.providers.github.client").issues
local issues_api = require("atlas.issues.providers.github.api.issues")
local users_api = require("atlas.providers.github.users").new("issues")
local issue_cache = require("atlas.issues.providers.github.api.cache")
local normalizer = require("atlas.issues.providers.github.api.mapper")

---@param ctx AtlasIssueActionContext
---@return boolean
local function has_issue(ctx)
	local issue = ctx.issue
	return issue ~= nil and tostring(issue.key or "") ~= ""
end

---@param issue Issue
---@return string
local function issue_slug(issue)
	local raw = issue._raw or {}
	local slug = tostring(raw.slug or "")
	if slug ~= "" then
		return slug
	end
	local from_key, _ = normalizer.parse_key(tostring(issue.key or ""))
	return from_key
end

---@param ctx AtlasIssueActionContext
---@return string|nil slug, string|nil err
local function create_issue_slug(ctx)
	local explicit = tostring(ctx.repo_slug or "")
	if explicit ~= "" then
		return explicit, nil
	end

	if has_issue(ctx) then
		local slug = issue_slug(assert(ctx.issue))
		if slug ~= "" then
			return slug, nil
		end
	end

	local git = require("atlas.core.git")
	local root, root_err = git.repo_root(nil)
	if not root then
		return nil, root_err or "Not in a git repository"
	end
	local remote, remote_err = git.remote_url(root, "origin")
	if not remote then
		return nil, remote_err or "No origin remote configured"
	end
	local info, parse_err = git.parse_remote_url(remote, "issues")
	if not info then
		return nil, parse_err or "Could not parse remote URL"
	end
	if info.provider ~= "github" then
		return nil, "Current repository is not hosted on GitHub"
	end
	return info.slug, nil
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
	statusline.notify("loading", string.format("Closing %s...", key))
	issues_api.set_state(key, "closed", function(ok, err)
		if not ok then
			statusline.notify("error", err or "Close failed")
			done(nil, err or "Close failed")
			return
		end
		statusline.notify("success", string.format("Closed %s", key), 1200)
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
	statusline.notify("loading", string.format("Reopening %s...", key))
	issues_api.set_state(key, "open", function(ok, err)
		if not ok then
			statusline.notify("error", err or "Reopen failed")
			done(nil, err or "Reopen failed")
			return
		end
		statusline.notify("success", string.format("Reopened %s", key), 1200)
		done({ issue_key = key }, nil)
	end)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function transition_available(ctx)
	if not has_issue(ctx) then
		return false, "No issue selected"
	end
	return true, nil
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function transition(ctx, done)
	local issue = assert(ctx.issue)
	local key = tostring(issue.key or "")
	local is_closed = tostring(issue.status_id or "") == "closed"
	local action = is_closed and reopen or close
	local verb = is_closed and "Reopen" or "Close"

	vim.ui.input({
		prompt = string.format("%s issue %s? [y/N]: ", verb, key),
	}, function(input)
		if input == nil or vim.trim(tostring(input)):lower() ~= "y" then
			done(nil, nil)
			return
		end

		action(ctx, done)
	end)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function assign_available(ctx)
	if not has_issue(ctx) then
		return false, "No issue selected"
	end
	return true, nil
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function assign(ctx, done)
	local issue = assert(ctx.issue)
	local key = tostring(issue.key or "")
	local slug = issue_slug(issue)
	if slug == "" then
		local err = "Could not determine repository"
		statusline.notify("error", err)
		done(nil, err)
		return
	end

	statusline.notify("loading", "Loading users...")
	users_api.get_assignable_users(slug, "", function(users, err)
		if err or users == nil then
			statusline.notify("error", err or "Failed to load users")
			done(nil, err or "Failed to load users")
			return
		end
		statusline.clear_notice()

		local items = {}
		for _, u in ipairs(users) do
			table.insert(items, { login = u.account_id, name = u.display_name or u.account_id })
		end
		if #items == 0 then
			local err = "No assignable users"
			statusline.notify("warn", err)
			done(nil, err)
			return
		end

		local raw = issue._raw or {}
		local original = {}
		local original_set = {}
		for _, a in ipairs(raw.assignees or {}) do
			local login = tostring(a.login or "")
			if login ~= "" then
				table.insert(original, { login = login, name = a.name or login })
				original_set[login] = true
			end
		end

		picker.multi_select({
			items = items,
			selected = vim.deepcopy(original),
			key = function(item)
				return item.login
			end,
			format_item = function(item)
				return string.format("%s %s", icons.general("user"), item.name or item.login)
			end,
			title = string.format("Assignees for %s", key),
			on_done = function(selected)
				local selected_set = {}
				for _, it in ipairs(selected) do
					selected_set[it.login] = true
				end

				local adds, removes = {}, {}
				for login, _ in pairs(selected_set) do
					if not original_set[login] then
						table.insert(adds, login)
					end
				end
				for login, _ in pairs(original_set) do
					if not selected_set[login] then
						table.insert(removes, login)
					end
				end

				if #adds == 0 and #removes == 0 then
					done(nil, nil)
					return
				end

				statusline.notify("loading", string.format("Updating assignees on %s...", key))
				issues_api.update_assignees(key, { add = adds, remove = removes }, function(ok, set_err)
					if not ok then
						statusline.notify("error", set_err or "Failed")
						done(nil, set_err or "Failed")
						return
					end
					local msg = string.format("+%d / -%d assignee(s)", #adds, #removes)
					statusline.notify("success", msg, 1200)
					done({ issue_key = key }, nil)
				end)
			end,
		})
	end)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function labels_available(ctx)
	if not has_issue(ctx) then
		return false, "No issue selected"
	end
	return true, nil
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function labels(ctx, done)
	local issue = assert(ctx.issue)
	local key = tostring(issue.key or "")
	local slug = issue_slug(issue)
	if slug == "" then
		local err = "Could not determine repository"
		statusline.notify("error", err)
		done(nil, err)
		return
	end

	statusline.notify("loading", "Loading labels...")
	issues_api.list_labels(slug, function(all_labels, err)
		if err or all_labels == nil then
			statusline.notify("error", err or "Failed to load labels")
			done(nil, err or "Failed to load labels")
			return
		end
		statusline.clear_notice()

		local items = {}
		for _, label in ipairs(all_labels) do
			table.insert(items, { name = label.name, color = label.color })
		end
		if #items == 0 then
			local err = "No labels available"
			statusline.notify("warn", err)
			done(nil, err)
			return
		end

		local raw = issue._raw or {}
		local original = {}
		local original_set = {}
		for _, label in ipairs(raw.labels or {}) do
			local name = tostring(label.name or "")
			if name ~= "" then
				table.insert(original, { name = name, color = label.color })
				original_set[name] = true
			end
		end

		picker.multi_select({
			items = items,
			selected = vim.deepcopy(original),
			key = function(item)
				return item.name
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

				statusline.notify("loading", string.format("Updating labels on %s...", key))
				issues_api.update_labels(key, { add = adds, remove = removes }, function(ok, set_err)
					if not ok then
						statusline.notify("error", set_err or "Failed")
						done(nil, set_err or "Failed")
						return
					end
					local msg = string.format("+%d / -%d label(s)", #adds, #removes)
					statusline.notify("success", msg, 1200)
					done({ issue_key = key }, nil)
				end)
			end,
		})
	end)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function create_issue(ctx, done)
	local slug, slug_err = create_issue_slug(ctx)
	if slug == nil or slug == "" then
		local err = slug_err or "Could not determine repository"
		statusline.notify("error", err)
		done(nil, err)
		return
	end

	local create_issue_ui = require("atlas.issues.create.github.issue")

	create_issue_ui.open({
		repo_slug = slug,
		on_done = function(result, err)
			if err then
				done(nil, tostring(err))
				return
			end

			local number = result and result.number
			if number == nil then
				done(nil, nil)
				return
			end
			done({ issue_key = string.format("%s#%d", slug, number) }, nil)
		end,
	})
end

---@param _ AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function search_issues(_, done)
	local state = require("atlas.issues.state")
	local view = state.active_view or state.current_view or {}
	local default = vim.trim(tostring(view.search or ""))
	if default == "" or not default:find("is:issue") then
		default = "is:issue " .. default
	end
	require("atlas.providers.github.completion.search").open(vim.trim(default) .. " ")
	done(nil, nil)
end

---@param _ AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function search(_, done)
	picker.search({
		title = "Search repositories",
		fetch_on_open = false,
		format_item = function(item)
			return item.label
		end,
		fetch = function(query, fetch_done)
			query = vim.trim(query)
			if query == "" then
				fetch_done({}, nil)
				return
			end

			return cli.gh({ "search", "repos", query, "--json", "fullName", "--limit", "20" }, function(result, err)
				if err then
					fetch_done(nil, tostring(err))
					return
				end

				local items = {}
				for _, repo in ipairs(type(result) == "table" and result or {}) do
					local full_name = tostring(repo.fullName or "")
					if full_name ~= "" then
						table.insert(items, { id = full_name, label = full_name })
					end
				end
				fetch_done(items, nil)
			end)
		end,
		on_select = function(item)
			---@type AtlasGitHubIssuesViewConfig
			local view = {
				name = "Search",
				search = string.format("repo:%s is:issue", item.id),
			}
			require("atlas").open("issues", "github", { initial_view = view })
			done(nil, nil)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function toggle_subscription_available(ctx)
	if not has_issue(ctx) then
		return false, "No issue selected"
	end
	local issue = assert(ctx.issue)
	local raw = issue._raw or {}
	if tostring(raw.node_id or "") == "" then
		return false, "Missing issue node id"
	end
	return true, nil
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function toggle_subscription(ctx, done)
	local issue = assert(ctx.issue)
	local raw = issue._raw or {}
	local node_id = tostring(raw.node_id or "")
	local next_state = issue.is_subscribed == true and "UNSUBSCRIBED" or "SUBSCRIBED"
	local gql =
		"mutation($id: ID!, $state: SubscriptionState!) { updateSubscription(input: { subscribableId: $id, state: $state }) { subscribable { ... on Issue { viewerSubscription } } } }"
	statusline.notify("loading", issue.is_subscribed and "Unsubscribing..." or "Subscribing...")
	require("atlas.providers.github.client").issues.gh(
		{ "api", "graphql", "-F", "id=" .. node_id, "-f", "state=" .. next_state, "-f", "query=" .. gql },
		function(_, err)
			if err then
				statusline.notify("error", tostring(err))
				done(nil, tostring(err))
				return
			end
			issue_cache.invalidate(tostring(issue.key or ""))
			issue.is_subscribed = (next_state == "SUBSCRIBED")
			statusline.notify("success", issue.is_subscribed and "Subscribed" or "Unsubscribed", 1200)
			done({ issue_key = issue.key }, nil)
		end
	)
end

register({ id = "close", label = "Close Issue", is_available = close_available, run = close })
register({ id = "reopen", label = "Reopen Issue", is_available = reopen_available, run = reopen })
register({
	id = "transition",
	label = "Transition Issue",
	hidden = true,
	is_available = transition_available,
	run = transition,
})
register({ id = "assign", label = "Edit Assignees", is_available = assign_available, run = assign })
register({ id = "labels", label = "Edit Labels", is_available = labels_available, run = labels })
register({ id = "create_issue", label = "Create Issue", run = create_issue })
register({ id = "search", label = "Search repositories", run = search })
register({ id = "search_issues", label = "Search issues", run = search_issues })
register(actions.manage_templates)
register(actions.browse_issue)
register(actions.copy_issue_key)
register({
	id = "toggle_subscription",
	label = "Toggle subscription",
	is_available = toggle_subscription_available,
	run = toggle_subscription,
})
register(actions.copy_issue_url)

---@param id AtlasGitHubIssueActionId
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
