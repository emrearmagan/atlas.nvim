local M = {}

local actions = require("atlas.issues.actions")
local icons = require("atlas.ui.shared.icons")
local picker = require("atlas.ui.picker")
local notify = require("atlas.core.notify")
local cli = require("atlas.providers.github.client")
local issues_api = require("atlas.issues.providers.github.api.issues")
local issue_cache = require("atlas.issues.providers.github.api.cache")

---@param ctx AtlasIssueActionContext
---@return string|nil slug, string|nil err
local function create_issue_slug(ctx)
	local explicit = tostring(ctx.repo_slug or "")
	if explicit ~= "" then
		return explicit, nil
	end

	if ctx.issue then
		local issue = assert(ctx.issue)
		---@cast issue GitHubIssue
		if issue.repo_full_name ~= "" then
			return issue.repo_full_name, nil
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
	local info, parse_err = git.parse_remote_url(remote)
	if not info then
		return nil, parse_err or "Could not parse remote URL"
	end
	if info.provider ~= "github" then
		return nil, "Current repository is not hosted on GitHub"
	end
	return info.repo_full_name, nil
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
	if ctx.issue == nil then
		return false, "No issue selected"
	end
	return assert(ctx.issue).status_id ~= "closed", "Issue is already closed"
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function close(ctx, done)
	local issue = assert(ctx.issue)
	local key = issue.key
	notify.loading(string.format("Closing %s...", key))
	issues_api.set_state(key, "closed", function(ok, err)
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
	if ctx.issue == nil then
		return false, "No issue selected"
	end
	return assert(ctx.issue).status_id == "closed", "Issue is not closed"
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function reopen(ctx, done)
	local issue = assert(ctx.issue)
	local key = issue.key
	notify.loading(string.format("Reopening %s...", key))
	issues_api.set_state(key, "open", function(ok, err)
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
---@return boolean, string|nil
local function transition_available(ctx)
	if ctx.issue == nil then
		return false, "No issue selected"
	end
	return true, nil
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function transition(ctx, done)
	local issue = assert(ctx.issue)
	local key = issue.key
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
	if ctx.issue == nil then
		return false, "No issue selected"
	end
	return true, nil
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function assign(ctx, done)
	local issue = assert(ctx.issue)
	local key = issue.key

	notify.loading("Loading assignees...")
	issues_api.get_assignee_options(key, function(current_assignees, assignable_users, assignees_err)
		if assignees_err or current_assignees == nil or assignable_users == nil then
			local message = assignees_err or "Failed to load assignees"
			notify.error(message)
			done(nil, message)
			return
		end
		notify.clear()

		if #assignable_users == 0 then
			local message = "No assignable users"
			notify.warn(message)
			done(nil, message)
			return
		end

		local original_set = {}
		for _, assignee in ipairs(current_assignees) do
			local login = tostring(assignee.account_id or "")
			if login ~= "" then
				original_set[login] = true
			end
		end

		picker.multi_select({
			items = assignable_users,
			selected = vim.deepcopy(current_assignees),
			key = function(item)
				return tostring(item.account_id or "")
			end,
			format_item = function(item)
				return string.format("%s %s", icons.general("user"), item.display_name or item.account_id)
			end,
			title = string.format("Assignees for %s", key),
			on_done = function(selected)
				local selected_set = {}
				for _, item in ipairs(selected) do
					local login = tostring(item.account_id or "")
					if login ~= "" then
						selected_set[login] = true
					end
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

				notify.loading(string.format("Updating assignees on %s...", key))
				issues_api.update_assignees(key, { add = adds, remove = removes }, function(ok, set_err)
					if not ok then
						notify.error(set_err or "Failed")
						done(nil, set_err or "Failed")
						return
					end
					local msg = string.format("+%d / -%d assignee(s)", #adds, #removes)
					notify.success(msg, { timeout = 1200 })
					done({ issue_key = key }, nil)
				end)
			end,
		})
	end)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function labels_available(ctx)
	if ctx.issue == nil then
		return false, "No issue selected"
	end
	return true, nil
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function labels(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue GitHubIssue
	local key = issue.key
	local slug = issue.repo_full_name
	if slug == "" then
		local err = "Could not determine repository"
		notify.error(err)
		done(nil, err)
		return
	end

	---@param current_labels IssueLabel[]
	---@param all_labels { name: string, color: string|nil }[]
	local function open_picker(current_labels, all_labels)
		notify.clear()

		local items = {}
		for _, label in ipairs(all_labels) do
			table.insert(items, { name = label.name, color = label.color })
		end
		if #items == 0 then
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

		issues_api.list_labels(slug, function(all_labels, labels_err)
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

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function create_issue(ctx, done)
	local slug, slug_err = create_issue_slug(ctx)
	if slug == nil or slug == "" then
		local err = slug_err or "Could not determine repository"
		notify.error(err)
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

---@param opts {
--- title: string,
--- include_all: boolean,
--- on_select: fun(repo: string),
--- on_cancel: fun(),
---}
local function select_repository(opts)
	local initial_items = opts.include_all and { { id = "all", label = "All repositories", repo = "" } } or {}
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

			return cli.gh({ "search", "repos", query, "--json", "fullName", "--limit", "20" }, function(result, err)
				if err then
					fetch_done(nil, tostring(err))
					return
				end

				local items = {}
				for _, repo in ipairs(result) do
					table.insert(items, { id = repo.fullName, label = repo.fullName, repo = repo.fullName })
				end
				fetch_done(items, nil)
			end, {
				action = "Search repositories",
				query = query,
			})
		end,
		on_select = function(item)
			opts.on_select(item.repo)
		end,
		on_cancel = opts.on_cancel,
	})
end

---@param repo string
---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function search_issues(repo, ctx, done)
	picker.search({
		title = repo ~= "" and "Search " .. repo .. " Issues" or "Search GitHub Issues",
		fetch_on_open = false,
		format_item = function(item)
			return item.label
		end,
		preview_item = function(item, preview_done)
			local issue = item.value
			return issues_api.get_issue(issue.key, function(details, err)
				if err or details == nil then
					preview_done({ title = issue.key, lines = { err or "Failed to load issue" } })
					return
				end
				local assignees = vim.tbl_map(function(user)
					return "@" .. tostring(user.account_id or user.display_name)
				end, details.assignees)
				local label_names = vim.tbl_map(function(label)
					return label.name
				end, details.labels)
				local author = issue.reporter and issue.reporter.display_name or "Unknown"
				local lines = {
					"**Status:** " .. tostring(issue.status or "Open"),
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
			local search = query .. " is:issue"
			if repo ~= "" then
				search = "repo:" .. repo .. " " .. search
			end
			return issues_api.search_issues(search, function(page, err)
				if err ~= nil then
					fetch_done(nil, err)
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
			end, {
				force_refresh = false,
				pagelen = 30,
			})
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
	select_repository({
		title = "Search Issues - Repository",
		include_all = true,
		on_select = function(repo)
			search_issues(repo, ctx, done)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param _ AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function open_repo(_, done)
	select_repository({
		title = "Open Repo",
		include_all = false,
		on_select = function(repo)
			require("atlas").open("issues", "github", {
				initial_view = {
					name = "Search",
					layout = "compact",
					search = "repo:" .. repo .. " is:issue",
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
---@return boolean, string|nil
local function toggle_subscription_available(ctx)
	if ctx.issue == nil then
		return false, "No issue selected"
	end
	local issue = assert(ctx.issue)
	---@cast issue GitHubIssue
	if tostring(issue.node_id or "") == "" then
		return false, "Missing issue node id"
	end
	return true, nil
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function toggle_subscription(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue GitHubIssue
	local node_id = tostring(issue.node_id or "")
	local next_state = issue.is_subscribed == true and "UNSUBSCRIBED" or "SUBSCRIBED"
	local gql =
		"mutation($id: ID!, $state: SubscriptionState!) { updateSubscription(input: { subscribableId: $id, state: $state }) { subscribable { ... on Issue { viewerSubscription } } } }"
	notify.loading(issue.is_subscribed and "Unsubscribing..." or "Subscribing...")
	require("atlas.providers.github.client").gh(
		{ "api", "graphql", "-F", "id=" .. node_id, "-f", "state=" .. next_state, "-f", "query=" .. gql },
		function(_, err)
			if err then
				notify.error(tostring(err))
				done(nil, tostring(err))
				return
			end
			issue_cache.invalidate(issue.key)
			issue.is_subscribed = (next_state == "SUBSCRIBED")
			notify.success(issue.is_subscribed and "Subscribed" or "Unsubscribed", { timeout = 1200 })
			done({ issue_key = issue.key }, nil)
		end,
		{
			action = issue.is_subscribed and "Unsubscribe from issue" or "Subscribe to issue",
			key = issue.key,
		}
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
register({ id = "search", label = "Search Issues", run = search })
register({ id = "open_repo", label = "Open Repo", run = open_repo })
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
