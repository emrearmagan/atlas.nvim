local M = {}

local actions = require("atlas.pulls.actions")
local cli = require("atlas.providers.github.client").pulls
local comments = require("atlas.pulls.providers.github.api.comments")
local pullrequests = require("atlas.pulls.providers.github.api.pullrequests")
local statusline = require("atlas.ui.statusline")
local multi_select = require("atlas.ui.popups.multi_select")
local github_mapping = require("atlas.providers.github.mapping")

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
	local callback = ctx.notify or statusline.notify
	callback(level, message, duration)
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
local function toggle_approval_available(ctx)
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
local function toggle_approval(ctx, done)
	local pr = ctx.pr
	if pr == nil then
		done(nil, "No PR selected")
		return
	end
	notify(ctx, "loading", "Checking approval...")
	comments.toggle_approval(pr, function(action, err)
		if action == nil then
			notify(ctx, "error", tostring(err))
			done(nil, tostring(err))
			return
		end

		local message = ({
			approved = "PR approved",
			unapproved = "PR unapproved",
			changes_request_dismissed = "Changes request dismissed",
		})[action]
		notify(ctx, "success", message, 1200)
		done({ changed_pr = true, message = message }, nil)
	end)
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
	local strategies = { "merge", "squash", "rebase" }

	vim.ui.select(strategies, {
		prompt = string.format("Merge strategy for PR #%s:", tostring(pr.id or "")),
		kind = "atlas_github_merge_strategy",
	}, function(strategy)
		if strategy == nil then
			done({ changed_pr = false, message = "Merge cancelled" }, nil)
			return
		end

		vim.ui.input({
			prompt = string.format("Confirm %s merge PR #%s? [y/N]: ", strategy, tostring(pr.id or "")),
		}, function(input)
			if input == nil then
				done({ changed_pr = false, message = "Merge cancelled" }, nil)
				return
			end

			local normalized = vim.trim(tostring(input)):lower()
			if normalized ~= "y" and normalized ~= "yes" then
				notify(ctx, "info", "Merge cancelled")
				done({ changed_pr = false, message = "Merge cancelled" }, nil)
				return
			end

			notify(ctx, "loading", "Merging PR...")
			cli.gh({
				"pr",
				"merge",
				tostring(pr.id),
				"--repo",
				slug,
				"--" .. strategy,
				"--delete-branch",
			}, function(_, err)
				if err then
					notify(ctx, "error", string.format("Merge failed: %s", tostring(err)))
					done(nil, tostring(err))
					return
				end

				notify(ctx, "success", "Merge succeeded", 1200)
				done({ changed_pr = true, message = "Merged" }, nil)
			end)
		end)
	end)
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function close_available(ctx)
	if not has_pr(ctx) or ctx.pr == nil then
		return false, "No PR selected"
	end
	if repo_slug(ctx) == "" then
		return false, "Missing repository info"
	end
	local state = tostring(ctx.pr.state or ""):lower()
	if state ~= "open" and state ~= "draft" then
		return false, "PR is not open"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function close(ctx, done)
	local pr = ctx.pr
	if pr == nil then
		done(nil, "No PR selected")
		return
	end

	vim.ui.input({
		prompt = string.format("Close PR #%s? [y/N]: ", tostring(pr.id or "")),
	}, function(input)
		if input == nil then
			done({ changed_pr = false, message = "Close cancelled" }, nil)
			return
		end

		local normalized = vim.trim(tostring(input)):lower()
		if normalized ~= "y" and normalized ~= "yes" then
			notify(ctx, "info", "Close cancelled")
			done({ changed_pr = false, message = "Close cancelled" }, nil)
			return
		end

		notify(ctx, "loading", "Closing PR...")
		cli.gh({
			"pr",
			"close",
			tostring(pr.id),
			"--repo",
			repo_slug(ctx),
		}, function(_, err)
			if err then
				notify(ctx, "error", string.format("Close failed: %s", tostring(err)))
				done(nil, tostring(err))
				return
			end

			notify(ctx, "success", "PR closed", 1200)
			done({ changed_pr = true, message = "Closed" }, nil)
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
	local issues_api = require("atlas.issues.providers.github.api.issues")

	notify(ctx, "loading", "Loading assignees...")
	issues_api.list_assignees(slug, function(items, err)
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

		local raw = pr._raw
		local raw_assignees = type(raw.assignees) == "table" and raw.assignees or {}
		local nodes = type(raw_assignees.nodes) == "table" and raw_assignees.nodes or {}
		local original = {}
		local original_set = {}
		for _, node in ipairs(nodes) do
			local login = type(node) == "table" and tostring(node.login or "") or ""
			if login ~= "" and not original_set[login] then
				original_set[login] = true
				table.insert(original, { account_id = login, display_name = login, email = "" })
			end
		end

		multi_select.open({
			items = items,
			selected = vim.deepcopy(original),
			key = function(item)
				return item.account_id
			end,
			format = function(item)
				return string.format(
					"@%s%s",
					item.account_id,
					item.display_name and item.display_name ~= item.account_id and (" — " .. item.display_name) or ""
				)
			end,
			prompt = string.format("Assignees for PR #%s:", tostring(pr.id or "")),
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
			done(nil, "No labels available")
			return
		end

		local raw = pr._raw
		local raw_labels = raw.labels
		if type(raw_labels) == "table" and type(raw_labels.nodes) == "table" then
			raw_labels = raw_labels.nodes
		end
		local original = {}
		local original_set = {}
		for _, label in ipairs(raw_labels or {}) do
			local name = tostring(label.name or "")
			if name ~= "" then
				table.insert(original, { name = name, color = label.color })
				original_set[name] = true
			end
		end

		multi_select.open({
			items = items,
			selected = vim.deepcopy(original),
			key = function(item)
				return item.name
			end,
			format = function(item)
				return tostring(item.name or "")
			end,
			prompt = string.format("Labels for PR #%s", tostring(pr.id or "")),
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
	vim.ui.input({ prompt = "Search repositories: " }, function(input)
		if input == nil or vim.trim(input) == "" then
			done({ changed_pr = false, message = "Search cancelled" }, nil)
			return
		end

		local query = vim.trim(input)
		notify(ctx, "loading", "Searching repositories...")
		cli.gh({ "search", "repos", query, "--json", "fullName", "--limit", "20" }, function(result, err)
			if err then
				notify(ctx, "error", string.format("Search failed: %s", tostring(err)))
				done(nil, tostring(err))
				return
			end

			local list = {}
			for _, item in ipairs(type(result) == "table" and result or {}) do
				local full_name = tostring(item.fullName or "")
				if full_name ~= "" then
					table.insert(list, full_name)
				end
			end

			if #list == 0 then
				notify(ctx, "warn", "No repositories found")
				done({ changed_pr = false, message = "No repositories found" }, nil)
				return
			end

			notify(ctx, "info", string.format("Found %d repositories", #list), 1200)

			vim.ui.select(list, {
				prompt = "Select repository",
				kind = "atlas_github_repo_select",
			}, function(repo)
				if repo == nil then
					done({ changed_pr = false, message = "Selection cancelled" }, nil)
					return
				end

				local search_query = string.format("repo:%s is:pr", repo)
				---@type AtlasGitHubViewConfig
				local search_view = {
					name = "Search",
					key = nil,
					search = search_query,
				}

				local controller = require("atlas.pulls.ui.main.controller")
				notify(ctx, "success", string.format("Search view -> %s", repo))
				controller.switch_view(search_view)
				done({ changed_pr = false, message = "Search view switched" }, nil)
			end)
		end)
	end)
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
	local raw = pr._raw
	local node_id = github_mapping.node_id(raw) or ""
	local next_state = pr.is_subscribed == true and "UNSUBSCRIBED" or "SUBSCRIBED"
	local gql =
		"mutation($id: ID!, $state: SubscriptionState!) { updateSubscription(input: { subscribableId: $id, state: $state }) { subscribable { ... on PullRequest { viewerSubscription } } } }"
	notify(ctx, "loading", pr.is_subscribed and "Unsubscribing..." or "Subscribing...")
	cli.gh(
		{ "api", "graphql", "-F", "id=" .. node_id, "-f", "state=" .. next_state, "-f", "query=" .. gql },
		function(_, err)
			if err then
				notify(ctx, "error", tostring(err))
				done(nil, tostring(err))
				return
			end
			pr.is_subscribed = (next_state == "SUBSCRIBED")
			notify(ctx, "success", pr.is_subscribed and "Subscribed" or "Unsubscribed", 1200)
			done({ changed_pr = true, message = pr.is_subscribed and "Subscribed" or "Unsubscribed" }, nil)
		end
	)
end

register({
	id = actions.request_changes.id,
	label = actions.request_changes.label,
	is_available = toggle_approval_available,
	run = actions.request_changes.run,
})

register({
	id = "toggle_approval",
	label = "Toggle approval",
	is_available = toggle_approval_available,
	run = toggle_approval,
})

register({
	id = "merge",
	label = "Merge",
	is_available = merge_available,
	run = merge,
})

register(actions.edit_title)

register({
	id = "close",
	label = "Close PR",
	is_available = close_available,
	run = close,
})

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
