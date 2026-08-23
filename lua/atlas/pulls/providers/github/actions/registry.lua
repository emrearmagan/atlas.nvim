local M = {}

local actions = require("atlas.pulls.actions")
local action_utils = require("atlas.pulls.actions.utils")
local cli = require("atlas.providers.github.client")
local notes = require("atlas.pulls.notes")
local picker = require("atlas.picker")
local pullrequests = require("atlas.pulls.providers.github.api.pullrequests")
local core_notify = require("atlas.core.notify")
local github_mapping = require("atlas.providers.github.mapping")
local users_api = require("atlas.providers.github.users")

---@param ctx AtlasPullActionContext
---@return boolean
local function has_pr(ctx)
	return ctx.pr ~= nil and ctx.pr.id ~= nil
end

---@param ctx AtlasPullActionContext
---@return string
local function repo_slug(ctx)
	return tostring((ctx.pr or {}).repo_full_name or "")
end

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
	if not has_pr(ctx) or ctx.pr == nil then
		return false, "No PR selected"
	end
	if repo_slug(ctx) == "" then
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
	if not has_pr(ctx) or ctx.pr == nil then
		return false, "No PR selected"
	end
	if repo_slug(ctx) == "" then
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

	local slug = repo_slug(ctx)
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
		end)
	end)
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function reopen_available(ctx)
	if not has_pr(ctx) or ctx.pr == nil then
		return false, "No PR selected"
	end
	if repo_slug(ctx) == "" then
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

	notify(ctx, "loading", "Reopening PR...")
	cli.gh({
		"pr",
		"reopen",
		tostring(pr.id),
		"--repo",
		repo_slug(ctx),
	}, function(_, err)
		if err then
			notify(ctx, "error", string.format("Reopen failed: %s", tostring(err)))
			done(nil, tostring(err))
			return
		end

		notify(ctx, "success", "PR reopened", 1200)
		done({ changed_pr = true, message = "Reopened" }, nil)
	end)
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function edit_assignees_available(ctx)
	if not has_pr(ctx) or ctx.pr == nil then
		return false, "No PR selected"
	end
	if repo_slug(ctx) == "" then
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

	local slug = repo_slug(ctx)
	local function open_picker()
		users_api.get_assignable_users(slug, nil, function(items, err)
			if err then
				notify(ctx, "error", string.format("Failed to load assignees: %s", tostring(err)))
				done(nil, tostring(err))
				return
			end

			items = type(items) == "table" and items or {}
			if #items == 0 then
				notify(ctx, "warn", "No assignees available")
				done({ changed_pr = false, message = "No assignees available" }, nil)
				return
			end

			local original = {}
			local original_set = {}
			for _, assignee in ipairs(pr.assignees or {}) do
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
						local message = string.format("+%d / -%d assignee(s)", #adds, #removes)
						notify(ctx, "success", message, 1200)
						done({ changed_pr = true, message = message }, nil)
					end)
				end,
			})
		end)
	end

	notify(ctx, "loading", "Loading assignees...")
	pullrequests.get_pr(pr.workspace, pr.repo, pr.id, function(details, err)
		if err or details == nil then
			local message = tostring(err or "Failed to load pull request")
			notify(ctx, "error", "Failed to load assignees: " .. message)
			done(nil, message)
			return
		end
		pr = details
		open_picker()
	end)
end
---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function edit_labels_available(ctx)
	if not has_pr(ctx) or ctx.pr == nil then
		return false, "No PR selected"
	end
	if repo_slug(ctx) == "" then
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
	local slug = repo_slug(ctx)

	notify(ctx, "loading", "Loading labels...")
	pullrequests.get_pr(pr.workspace, pr.repo, pr.id, function(current, current_err)
		if current_err or current == nil then
			notify(ctx, "error", current_err or "Failed to load PR labels")
			done(nil, current_err or "Failed to load PR labels")
			return
		end

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
			for _, label in ipairs(current.labels or {}) do
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
	if not has_pr(ctx) or ctx.pr == nil then
		return false, "No PR selected"
	end
	if repo_slug(ctx) == "" then
		return false, "Missing repository info"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function create_issue(ctx, done)
	local slug = repo_slug(ctx)
	if slug == "" then
		done(nil, "Missing repository info")
		return
	end

	local create_issue_ui = require("atlas.issues.create.github.issue")
	create_issue_ui.open({ repo_slug = slug })
	done({ changed_pr = false, message = "Opened issue editor" }, nil)
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function search(ctx, done)
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

				local list = {}
				for _, item in ipairs(type(result) == "table" and result or {}) do
					local full_name = tostring(item.fullName or "")
					if full_name ~= "" then
						table.insert(list, { id = full_name, label = full_name })
					end
				end
				fetch_done(list, nil)
			end)
		end,
		on_select = function(item)
			local repo = item.id
			---@type AtlasGitHubViewConfig
			local search_view = {
				name = "Search",
				key = nil,
				search = string.format("repo:%s is:pr", repo),
			}

			notify(ctx, "success", string.format("Search view -> %s", repo))
			require("atlas").open("pulls", "github", { initial_view = search_view })
			done({ changed_pr = false, message = "Search view switched" }, nil)
		end,
		on_cancel = function()
			done({ changed_pr = false, message = "Search cancelled" }, nil)
		end,
	})
end

---@param _ AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function search_pull_requests(_, done)
	local state = require("atlas.pulls.state")
	local view = state.active_view or state.current_view or {}
	local query = vim.trim(tostring(view.search or ""))
	if query == "" or not query:find("is:pr", 1, true) then
		query = "is:pr " .. query
	end
	require("atlas.providers.github.completion.search").open(vim.trim(query) .. " ")
	done(nil, nil)
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function toggle_subscription_available(ctx)
	if not has_pr(ctx) or ctx.pr == nil then
		return false, "No PR selected"
	end
	local raw = ctx.pr._raw
	if github_mapping.node_id(raw) == nil then
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
	pullrequests.get_pr(pr.workspace, pr.repo, pr.id, function(details, fetch_err)
		if fetch_err or details == nil then
			local message = tostring(fetch_err or "Failed to load pull request")
			notify(ctx, "error", message)
			done(nil, message)
			return
		end
		local node_id = github_mapping.node_id(details._raw) or ""
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
			end
		)
	end)
end

register({
	id = actions.approve.id,
	label = actions.approve.label,
	is_available = review_available,
	run = actions.approve.run,
})

register({
	id = actions.request_changes.id,
	label = actions.request_changes.label,
	is_available = review_available,
	run = actions.request_changes.run,
})

register({
	id = "merge",
	label = "Merge",
	is_available = merge_available,
	run = merge,
})

register(actions.edit_title)
register(actions.edit_description)

register(actions.decline)

register({
	id = "reopen",
	label = "Reopen PR",
	is_available = reopen_available,
	run = reopen,
})

register(actions.ready_for_review)
register(actions.convert_to_draft)
register(actions.edit_reviewers)

register({
	id = "edit_assignees",
	label = "Edit assignees",
	is_available = edit_assignees_available,
	run = edit_assignees,
})

register({
	id = "labels",
	label = "Edit labels",
	is_available = edit_labels_available,
	run = edit_labels,
})

register({
	id = "create_issue",
	label = "Create issue",
	is_available = create_issue_available,
	run = create_issue,
})

register({
	id = "search",
	label = "Search repositories",
	run = search,
})

register({
	id = "search_pull_requests",
	label = "Search pull requests",
	run = search_pull_requests,
})

register({
	id = "toggle_subscription",
	label = "Toggle subscription",
	is_available = toggle_subscription_available,
	run = toggle_subscription,
})

register(actions.open_pipelines)
register(actions.open_diff)
register(actions.checkout)

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
