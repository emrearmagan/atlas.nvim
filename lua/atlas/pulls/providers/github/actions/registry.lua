local M = {}

local actions = require("atlas.pulls.actions")
local action_utils = require("atlas.pulls.actions.utils")
local icons = require("atlas.ui.shared.icons")
local cli = require("atlas.providers.github.client")
local notes = require("atlas.pulls.notes")
local picker = require("atlas.ui.picker")
local pullrequests = require("atlas.pulls.providers.github.api.pullrequests")
local core_notify = require("atlas.core.notify")
local users_api = require("atlas.providers.github.users")

---@param ctx AtlasPullActionContext
---@param level "loading"|"success"|"warn"|"error"|"info"
---@param message string
---@param duration integer|nil
local function notify(ctx, level, message, duration)
	if ctx.notify then
		ctx.notify(level, message, duration)
		return
	end
	core_notify.show(level, message, { timeout = duration })
end

---@type AtlasPullAction[]
local ACTIONS = {}
M.items = ACTIONS

---@param action AtlasPullAction
local function register(action)
	table.insert(ACTIONS, action)
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function review_available(ctx)
	if ctx.pr == nil then
		return false, "No PR selected"
	end
	if ctx.pr.repo_full_name == "" then
		return false, "Missing repository info"
	end
	if ctx.pr.state ~= "open" and ctx.pr.state ~= "draft" then
		return false, "PR is not open"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function merge_available(ctx)
	if ctx.pr == nil then
		return false, "No PR selected"
	end
	if ctx.pr.repo_full_name == "" then
		return false, "Missing repository info"
	end
	if ctx.pr.state ~= "open" then
		return false, "PR is not open"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function merge(ctx, done)
	local pr = ctx.pr
	if pr == nil then
		done(nil, "No PR selected")
		return
	end

	local slug = pr.repo_full_name
	local options = action_utils.merge_options()
	local label = options.method == "squash" and "squash merge" or "merge"
	vim.ui.input({
		prompt = string.format("Confirm %s of PR #%s? [y/N]: ", label, tostring(pr.id or "")),
	}, function(input)
		if not input or not vim.trim(input):lower():match("^y") then
			done({ changed_pr = false, message = "Merge cancelled" }, nil)
			return
		end
		local args = { "pr", "merge", tostring(pr.id), "--repo", slug, "--" .. options.method }
		if options.delete_branch then
			table.insert(args, "--delete-branch")
		end
		notify(ctx, "loading", "Merging PR...")
		cli.gh(args, function(_, err)
			if err then
				notify(ctx, "error", string.format("Merge failed: %s", tostring(err)))
				done(nil, tostring(err))
				return
			end
			notify(ctx, "success", "Merge succeeded", 1200)
			notes.clear_for_pull_request(pr)
			done({ changed_pr = true, message = "Merged" }, nil)
		end, {
			action = "Merge PR",
			repo = slug,
			number = pr.id,
			method = options.method,
		})
	end)
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function reopen_available(ctx)
	if ctx.pr == nil then
		return false, "No PR selected"
	end
	if ctx.pr.repo_full_name == "" then
		return false, "Missing repository info"
	end
	if tostring(ctx.pr.state or ""):lower() ~= "declined" then
		return false, "PR is not closed"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function reopen(ctx, done)
	local pr = ctx.pr
	if pr == nil then
		done(nil, "No PR selected")
		return
	end
	local slug = pr.repo_full_name

	notify(ctx, "loading", "Reopening PR...")
	cli.gh({
		"pr",
		"reopen",
		tostring(pr.id),
		"--repo",
		slug,
	}, function(_, err)
		if err then
			notify(ctx, "error", string.format("Reopen failed: %s", tostring(err)))
			done(nil, tostring(err))
			return
		end

		notify(ctx, "success", "PR reopened", 1200)
		done({ changed_pr = true, message = "Reopened" }, nil)
	end, {
		action = "Reopen PR",
		repo = slug,
		number = pr.id,
	})
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function edit_assignees_available(ctx)
	if ctx.pr == nil then
		return false, "No PR selected"
	end
	if ctx.pr.repo_full_name == "" then
		return false, "Missing repository info"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function edit_assignees(ctx, done)
	local pr = ctx.pr
	if pr == nil then
		done(nil, "No PR selected")
		return
	end

	local slug = pr.repo_full_name
	---@param assignees PullsAuthor[]
	local function open_picker(assignees)
		users_api.get_assignable_users(slug, nil, function(items, err)
			if err then
				notify(ctx, "error", string.format("Failed to load assignees: %s", tostring(err)))
				done(nil, tostring(err))
				return
			end

			items = items or {}
			if #items == 0 then
				notify(ctx, "warn", "No assignees available")
				done({ changed_pr = false, message = "No assignees available" }, nil)
				return
			end

			local original = {}
			local original_set = {}
			for _, assignee in ipairs(assignees) do
				local login = assignee.username
				if login ~= "" and not original_set[login] then
					original_set[login] = true
					table.insert(original, { account_id = login, display_name = assignee.name, email = "" })
				end
			end
			notify(ctx, "success", "Assignees loaded", 1200)

			picker.multi_select({
				items = items,
				selected = vim.deepcopy(original),
				key = function(item)
					return item.account_id
				end,
				format_item = function(item)
					return string.format(
						"@%s%s",
						item.account_id,
						item.display_name and item.display_name ~= item.account_id and (" — " .. item.display_name)
							or ""
					)
				end,
				title = string.format("Assignees for PR #%s", tostring(pr.id or "")),
				on_done = function(selected)
					local selected_set = {}
					for _, item in ipairs(selected) do
						selected_set[item.account_id] = true
					end

					local adds, removes = {}, {}
					for login in pairs(selected_set) do
						if not original_set[login] then
							table.insert(adds, login)
						end
					end
					for login in pairs(original_set) do
						if not selected_set[login] then
							table.insert(removes, login)
						end
					end

					if #adds == 0 and #removes == 0 then
						done({ changed_pr = false, message = "No changes" }, nil)
						return
					end

					local args = { "pr", "edit", tostring(pr.id), "--repo", slug }
					for _, login in ipairs(adds) do
						table.insert(args, "--add-assignee")
						table.insert(args, login)
					end
					for _, login in ipairs(removes) do
						table.insert(args, "--remove-assignee")
						table.insert(args, login)
					end

					notify(ctx, "loading", string.format("Updating assignees on PR #%s...", tostring(pr.id or "")))
					cli.gh(args, function(_, edit_err)
						if edit_err then
							notify(ctx, "error", string.format("Update assignees failed: %s", tostring(edit_err)))
							done(nil, tostring(edit_err))
							return
						end
						cli.delete_mem(string.format("github:pr:%s:%s", slug, tostring(pr.id)))
						local message = string.format("+%d / -%d assignee(s)", #adds, #removes)
						notify(ctx, "success", message, 1200)
						done({ changed_pr = true, message = message }, nil)
					end, {
						action = "Update PR assignees",
						repo = slug,
						number = pr.id,
						added = #adds,
						removed = #removes,
					})
				end,
			})
		end)
	end

	notify(ctx, "loading", "Loading assignees...")
	if ctx.details then
		---@cast ctx.details GitHubPullRequestDetails
		open_picker(ctx.details.assignees)
		return
	end
	pullrequests.get_pr(pr.workspace, pr.repo, pr.id, function(details, err)
		if err or details == nil then
			local message = tostring(err or "Failed to load pull request")
			notify(ctx, "error", "Failed to load assignees: " .. message)
			done(nil, message)
			return
		end
		---@cast details GitHubPullRequestDetails
		open_picker(details.assignees)
	end)
end
---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function edit_labels_available(ctx)
	if ctx.pr == nil then
		return false, "No PR selected"
	end
	if ctx.pr.repo_full_name == "" then
		return false, "Missing repository info"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function edit_labels(ctx, done)
	local pr = ctx.pr
	if pr == nil then
		done(nil, "No PR selected")
		return
	end
	local slug = pr.repo_full_name

	notify(ctx, "loading", "Loading labels...")
	pullrequests.get_pr(pr.workspace, pr.repo, pr.id, function(current, current_err)
		if current_err or current == nil then
			notify(ctx, "error", current_err or "Failed to load PR labels")
			done(nil, current_err or "Failed to load PR labels")
			return
		end
		---@cast current GitHubPullRequestDetails

		pullrequests.list_labels(slug, function(labels, err)
			if err or labels == nil then
				notify(ctx, "error", err or "Failed to load labels")
				done(nil, err or "Failed to load labels")
				return
			end

			local items = {}
			for _, label in ipairs(labels) do
				table.insert(items, { name = label.name, color = label.color })
			end

			if #items == 0 then
				notify(ctx, "warn", "No labels available")
				done({ changed_pr = false, message = "No labels available" }, nil)
				return
			end

			local original = {}
			local original_set = {}
			for _, label in ipairs(current.labels) do
				local name = tostring(label.name or "")
				if name ~= "" then
					table.insert(original, { name = name, color = label.color })
					original_set[name] = true
				end
			end
			notify(ctx, "success", "Labels loaded", 1200)

			picker.multi_select({
				items = items,
				selected = vim.deepcopy(original),
				key = function(item)
					return item.name
				end,
				format_item = function(item)
					return tostring(item.name or "")
				end,
				title = string.format("Labels for PR #%s", tostring(pr.id or "")),
				on_done = function(selected)
					local selected_set = {}
					for _, item in ipairs(selected) do
						selected_set[item.name] = true
					end

					local adds, removes = {}, {}
					for name in pairs(selected_set) do
						if not original_set[name] then
							table.insert(adds, name)
						end
					end
					for name in pairs(original_set) do
						if not selected_set[name] then
							table.insert(removes, name)
						end
					end

					if #adds == 0 and #removes == 0 then
						done({ changed_pr = false, message = "No changes" }, nil)
						return
					end

					notify(ctx, "loading", string.format("Updating labels on #%s...", tostring(pr.id or "")))
					pullrequests.update_labels(slug, pr.id, { add = adds, remove = removes }, function(ok, set_err)
						if not ok then
							notify(ctx, "error", set_err or "Failed")
							done(nil, set_err or "Failed")
							return
						end
						local message = string.format("+%d / -%d label(s)", #adds, #removes)
						notify(ctx, "success", message, 1200)
						done({ changed_pr = true, message = message }, nil)
					end)
				end,
			})
		end)
	end)
end
---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function create_issue_available(ctx)
	if ctx.pr == nil then
		return false, "No PR selected"
	end
	if ctx.pr.repo_full_name == "" then
		return false, "Missing repository info"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function create_issue(ctx, done)
	local pr = ctx.pr
	if pr == nil then
		done(nil, "No PR selected")
		return
	end
	local slug = pr.repo_full_name
	if slug == "" then
		done(nil, "Missing repository info")
		return
	end

	local create_issue_ui = require("atlas.issues.create.github.issue")
	create_issue_ui.open({ repo_slug = slug })
	done({ changed_pr = false, message = "Opened issue editor" }, nil)
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
---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function search_results(repo, ctx, done)
	picker.search({
		title = repo ~= "" and "Search " .. repo .. " Pull Requests" or "Search GitHub Pull Requests",
		fetch_on_open = false,
		format_item = function(item)
			return item.label
		end,
		preview_item = function(item, preview_done)
			local pr = item.value
			return pullrequests.get_pr(pr.workspace, pr.repo, pr.id, function(details, err)
				if err or details == nil then
					preview_done({ title = item.label, lines = { err or "Failed to load pull request" } })
					return
				end
				---@cast details GitHubPullRequestDetails

				local assignees = vim.tbl_map(function(user)
					return "@" .. user.username
				end, details.assignees)
				local labels = vim.tbl_map(function(label)
					return label.name
				end, details.labels)
				local lines = {
					"**Status:** " .. pr.state,
					"**Author:** @" .. pr.author.username,
					string.format("**Branches:** %s -> %s", pr.source.branch, pr.destination.branch),
				}
				if #assignees > 0 then
					table.insert(lines, "**Assignees:** " .. table.concat(assignees, ", "))
				end
				if #labels > 0 then
					table.insert(lines, "**Labels:** " .. table.concat(labels, ", "))
				end
				vim.list_extend(lines, { "", "## Description", "" })
				local description = vim.trim(details.description)
				vim.list_extend(
					lines,
					vim.split(description ~= "" and description or "No description", "\n", { plain = true })
				)
				preview_done({ title = item.label, lines = lines })
			end)
		end,
		fetch = function(query, fetch_done)
			query = vim.trim(query)
			if query == "" then
				fetch_done({}, nil)
				return
			end
			local search = query .. " is:pr"
			if repo ~= "" then
				search = "repo:" .. repo .. " " .. search
			end
			return pullrequests.fetch_search({ search }, { force_refresh = false, pagelen = 30 }, function(page, errors)
				if errors then
					fetch_done(nil, table.concat(errors, "\n"))
					return
				end
				local items = {}
				for _, pr in ipairs(page.items) do
					local id = string.format("%s#%s", pr.repo_full_name, tostring(pr.id))
					table.insert(items, { id = id, label = id .. " - " .. pr.title, value = pr })
				end
				fetch_done(items, nil)
			end)
		end,
		on_select = function(item)
			require("atlas.pulls.ui.detail").open(item.value, { provider = ctx.provider })
			done(nil, nil)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function search(ctx, done)
	select_repository({
		title = "Search Pull Requests - Repository",
		include_all = true,
		on_select = function(repo)
			search_results(repo, ctx, done)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param _ AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function open_repo(_, done)
	select_repository({
		title = "Open Repo",
		include_all = false,
		on_select = function(repo)
			require("atlas").open("pulls", "github", {
				initial_view = {
					name = "Search",
					layout = "compact",
					search = "repo:" .. repo .. " is:pr",
				},
			})
			done(nil, nil)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function toggle_subscription_available(ctx)
	if ctx.pr == nil then
		return false, "No PR selected"
	end
	local pr = ctx.pr
	---@cast pr GitHubPullRequest
	if not pr.node_id or pr.node_id == "" then
		return false, "Missing PR node id"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function toggle_subscription(ctx, done)
	local pr = ctx.pr
	if pr == nil then
		done(nil, "No PR selected")
		return
	end
	---@cast pr GitHubPullRequest
	---@param details PullRequestDetails
	local function update(details)
		local node_id = pr.node_id or ""
		local next_state = details.is_subscribed == true and "UNSUBSCRIBED" or "SUBSCRIBED"
		local gql =
			"mutation($id: ID!, $state: SubscriptionState!) { updateSubscription(input: { subscribableId: $id, state: $state }) { subscribable { ... on PullRequest { viewerSubscription } } } }"
		notify(ctx, "loading", details.is_subscribed and "Unsubscribing..." or "Subscribing...")
		cli.gh(
			{ "api", "graphql", "-F", "id=" .. node_id, "-f", "state=" .. next_state, "-f", "query=" .. gql },
			function(_, err)
				if err then
					notify(ctx, "error", tostring(err))
					done(nil, tostring(err))
					return
				end
				details.is_subscribed = (next_state == "SUBSCRIBED")
				notify(ctx, "success", details.is_subscribed and "Subscribed" or "Unsubscribed", 1200)
				done({
					changed_pr = true,
					message = details.is_subscribed and "Subscribed" or "Unsubscribed",
				}, nil)
			end,
			{
				action = details.is_subscribed and "Unsubscribe from PR" or "Subscribe to PR",
				repo = pr.repo_full_name,
				number = pr.id,
			}
		)
	end

	if ctx.details then
		update(ctx.details)
		return
	end
	pullrequests.get_pr(pr.workspace, pr.repo, pr.id, function(details, fetch_err)
		if fetch_err or details == nil then
			local message = tostring(fetch_err or "Failed to load pull request details")
			notify(ctx, "error", message)
			done(nil, message)
			return
		end
		update(details)
	end)
end

register({
	id = actions.approve.id,
	label = actions.approve.label,
	icon = actions.approve.icon,
	is_available = review_available,
	run = actions.approve.run,
})

register({
	id = actions.request_changes.id,
	label = actions.request_changes.label,
	icon = actions.request_changes.icon,
	is_available = review_available,
	run = actions.request_changes.run,
})

register({
	id = "merge",
	label = "Merge",
	icon = icons.action("merge"),
	is_available = merge_available,
	run = merge,
})

register(actions.decline)
register(actions.convert_to_draft)
register(actions.ready_for_review)

register({
	id = "reopen",
	label = "Reopen PR",
	icon = icons.action("reopen"),
	is_available = reopen_available,
	run = reopen,
})

register(actions.edit_title)
register(actions.edit_description)
register(actions.edit_reviewers)

register({
	id = "edit_assignees",
	label = "Edit assignees",
	icon = icons.action("user"),
	is_available = edit_assignees_available,
	run = edit_assignees,
})

register({
	id = "labels",
	label = "Edit labels",
	icon = icons.action("label"),
	is_available = edit_labels_available,
	run = edit_labels,
})

register({
	id = "search",
	label = "Search Pull Requests",
	icon = icons.action("search"),
	run = search,
})

register({
	id = "open_repo",
	label = "Open Repo",
	icon = icons.action("search"),
	run = open_repo,
})

register({
	id = "search_pull_requests",
	label = "Open Search View",
	icon = icons.action("search"),
	run = function(_, done)
		local query = require("atlas.pulls.state").query
		require("atlas.providers.github.completion.search").open(query .. " ")
		done(nil, nil)
	end,
})

register({
	id = "edit_search",
	label = "Edit search",
	icon = icons.action("search"),
	run = function(_, done)
		local state = require("atlas.pulls.state")
		require("atlas.providers.github.completion.search").edit(state.query .. " ", function(query)
			local view = state.search_view()
			if view then
				view.search = query
				view._states = nil
				require("atlas.pulls.ui.dashboard.controller").refresh_view()
			end
		end)
		done(nil, nil)
	end,
})

register({
	id = "toggle_subscription",
	label = "Toggle subscription",
	icon = icons.action("notification"),
	is_available = toggle_subscription_available,
	run = toggle_subscription,
})

register(actions.open_pipelines)
register(actions.open_diff)
register(actions.checkout)

register({
	id = "create_issue",
	label = "Create issue",
	icon = icons.action("create"),
	is_available = create_issue_available,
	run = create_issue,
})

register(actions.copy_id)
register(actions.copy_url)
register(actions.open_in_browser)

---@param id AtlasGitHubActionId
---@return AtlasPullAction|nil
function M.find(id)
	for _, action in ipairs(ACTIONS) do
		if action.id == id then
			return action
		end
	end
	return nil
end

return M
