local M = {}

local actions = require("atlas.pulls.actions")
local action_utils = require("atlas.pulls.actions.utils")
local icons = require("atlas.ui.shared.icons")
local bitbucket_query = require("atlas.providers.bitbucket.query")
local bitbucket_search = require("atlas.providers.bitbucket.completion.search")
local notes = require("atlas.pulls.notes")
local picker = require("atlas.ui.picker")
local state = require("atlas.pulls.state")
local pullrequests = require("atlas.pulls.providers.bitbucket.api.pullrequests")
local reviews = require("atlas.pulls.providers.bitbucket.api.reviews")
local users_api = require("atlas.pulls.providers.bitbucket.api.users")
local repositories = require("atlas.pulls.providers.bitbucket.api.repositories")
local core_notify = require("atlas.core.notify")

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
local function approve_available(ctx)
	if ctx.pr == nil then
		return false, "No PR selected"
	end
	if not reviews.has_action(ctx.pr, "approve") then
		return false, "No approve URL available"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function merge_available(ctx)
	if ctx.pr == nil then
		return false, "No PR selected"
	end
	if not pullrequests.has_action(ctx.pr, "merge") then
		return false, "No merge URL available"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function decline_available(ctx)
	if not actions.decline.is_available(ctx) or ctx.pr == nil then
		return false, "PR is not open"
	end
	if not pullrequests.has_action(ctx.pr, "decline") then
		return false, "No decline URL available"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function request_changes_available(ctx)
	if ctx.pr == nil then
		return false, "No PR selected"
	end
	if not reviews.has_action(ctx.pr, "request_changes") then
		return false, "No request changes URL available"
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

	local options = action_utils.merge_options()
	local label = options.method == "squash" and "squash merge" or "merge"
	vim.ui.input({
		prompt = string.format("Confirm %s of PR #%s? [y/N]: ", label, tostring(pr.id or "")),
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

		notify(ctx, "loading", "Starting Merge...")
		pullrequests.merge(pr, {
			merge_strategy = options.method == "merge" and "merge_commit" or options.method,
			close_source_branch = options.delete_branch,
		}, function(_, err)
			if err ~= nil then
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
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function search(ctx, done)
	notify(ctx, "loading", "Loading workspaces...")
	users_api.fetch_workspaces(function(workspaces, err)
		if err ~= nil then
			notify(ctx, "error", string.format("Failed loading workspaces: %s", tostring(err)))
			done(nil, tostring(err))
			return
		end

		local ws = workspaces or {}
		if #ws == 0 then
			notify(ctx, "warn", "No workspaces found")
			done({ changed_pr = false, message = "No workspaces found" }, nil)
			return
		end

		notify(ctx, "info", string.format("Loaded %d workspaces", #ws), 1200)

		---@param selected_ws BitbucketWorkspace
		local function continue_with_workspace(selected_ws)
			if selected_ws.slug == "" then
				notify(ctx, "warn", "Invalid workspace selection")
				done({ changed_pr = false, message = "Invalid workspace" }, nil)
				return
			end

			picker.search({
				title = string.format("Repositories in %s", selected_ws.slug),
				format_item = function(repo)
					return repo.full_name ~= "" and repo.full_name or repo.name
				end,
				fetch = function(query, fetch_done)
					return repositories.fetch_workspace_repositories(selected_ws.slug, vim.trim(query), fetch_done)
				end,
				on_select = function(repo)
					---@type AtlasBitbucketViewConfig
					local search_view = {
						name = "Search",
						key = nil,
						layout = "compact",
						search = bitbucket_query.for_repo(repo.owner, repo.repo_name),
					}

					notify(ctx, "success", string.format("Search view -> %s", tostring(repo.full_name or repo.name)))
					require("atlas").open("pulls", "bitbucket", { initial_view = search_view })
					done({ changed_pr = false, message = "Search view switched" }, nil)
				end,
				on_cancel = function()
					done({ changed_pr = false, message = "Search cancelled" }, nil)
				end,
			})
		end

		if #ws == 1 then
			continue_with_workspace(ws[1])
			return
		end

		picker.select({
			title = "Select workspace",
			items = ws,
			format_item = function(item)
				return item.slug
			end,
			on_select = function(selected)
				if selected == nil then
					done({ changed_pr = false, message = "Selection cancelled" }, nil)
					return
				end
				continue_with_workspace(selected)
			end,
		})
	end)
end

register({
	id = actions.approve.id,
	label = actions.approve.label,
	icon = actions.approve.icon,
	is_available = approve_available,
	run = actions.approve.run,
})

register({
	id = actions.request_changes.id,
	label = actions.request_changes.label,
	icon = actions.request_changes.icon,
	is_available = request_changes_available,
	run = actions.request_changes.run,
})

register({
	id = "merge",
	label = "Merge",
	icon = icons.action("merge"),
	is_available = merge_available,
	run = merge,
})

register({
	id = actions.decline.id,
	label = actions.decline.label,
	icon = actions.decline.icon,
	is_available = decline_available,
	run = actions.decline.run,
})

register(actions.edit_title)
register(actions.edit_description)
register(actions.ready_for_review)
register(actions.convert_to_draft)
register(actions.edit_reviewers)

register({
	id = "search",
	label = "Search repositories",
	icon = icons.action("search"),
	run = search,
})

register({
	id = "search_pull_requests",
	label = "Search pull requests",
	icon = icons.action("search"),
	run = function(_, done)
		bitbucket_search.open({ name = "Search", search = state.query })
		done(nil, nil)
	end,
})

register(actions.open_pipelines)
register(actions.open_diff)
register(actions.checkout)

register(actions.copy_id)
register(actions.copy_url)
register(actions.open_in_browser)

---@param id AtlasPullActionId
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
