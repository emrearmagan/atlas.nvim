local M = {}

local actions = require("atlas.pulls.actions")
local pullrequests = require("atlas.pulls.providers.bitbucket.api.pullrequests")
local reviews = require("atlas.pulls.providers.bitbucket.api.reviews")
local users_api = require("atlas.pulls.providers.bitbucket.api.users")
local repositories = require("atlas.pulls.providers.bitbucket.api.repositories")
local statusline = require("atlas.ui.statusline")

---@param ctx AtlasPullActionContext
---@return boolean
local function has_pr(ctx)
	return ctx.pr ~= nil and ctx.pr.id ~= nil
end

---@param pr PullRequest
---@param current_user PullsUser
---@return boolean
local function is_approved(pr, current_user)
	for _, reviewer in ipairs(pr.reviewers or {}) do
		if
			reviewer.id == current_user.id
			or (reviewer.username ~= "" and reviewer.username == current_user.username)
		then
			return reviewer.decision == "approved"
		end
	end
	return false
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
	if not reviews.has_action(ctx.pr, "approve") then
		return false, "No approve URL available"
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
	if ctx.current_user == nil then
		notify(ctx, "error", "Current user is unavailable")
		done(nil, "Current user is unavailable")
		return
	end

	notify(ctx, "loading", "Checking approval...")
	pullrequests.fetch_pullrequest(pr, { force_load = true }, function(fresh_pr, err)
		if not fresh_pr then
			local message = tostring(err or "Unable to load pull request")
			notify(ctx, "error", message)
			done(nil, message)
			return
		end

		local approved = is_approved(fresh_pr, ctx.current_user)
		local update = approved and reviews.unapprove or reviews.approve
		notify(ctx, "loading", approved and "Unapproving PR..." or "Approving PR...")
		update(fresh_pr, function(_, update_err)
			if update_err ~= nil then
				local action = approved and "Unapprove" or "Approve"
				notify(ctx, "error", string.format("%s failed: %s", action, tostring(update_err)))
				done(nil, tostring(update_err))
				return
			end

			local message = approved and "Unapproved" or "Approved"
			notify(ctx, "success", "PR " .. message:lower(), 1200)
			done({ changed_pr = true, message = message }, nil)
		end)
	end)
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function merge_available(ctx)
	if not has_pr(ctx) or ctx.pr == nil then
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
	if not has_pr(ctx) or ctx.pr == nil then
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

	vim.ui.input({
		prompt = string.format("Confirm merge PR #%s? [y/N]: ", tostring(pr.id or "")),
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
		pullrequests.merge(pr, {}, function(_, err)
			if err ~= nil then
				notify(ctx, "error", string.format("Merge failed: %s", tostring(err)))
				done(nil, tostring(err))
				return
			end

			notify(ctx, "success", "Merge succeeded", 1200)
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

		local function continue_with_workspace(selected_ws)
			if type(selected_ws) ~= "table" or tostring(selected_ws.slug or "") == "" then
				notify(ctx, "warn", "Invalid workspace selection")
				done({ changed_pr = false, message = "Invalid workspace" }, nil)
				return
			end

			vim.ui.input({ prompt = string.format("Search repos in %s: ", selected_ws.slug) }, function(input)
				if input == nil then
					done({ changed_pr = false, message = "Search cancelled" }, nil)
					return
				end

				notify(ctx, "loading", "Searching repositories...")
				repositories.fetch_workspace_repositories(selected_ws.slug, input, function(repos, repo_err)
					if repo_err ~= nil then
						notify(ctx, "error", string.format("Repo search failed: %s", tostring(repo_err)))
						done(nil, tostring(repo_err))
						return
					end

					local list = repos or {}
					if #list == 0 then
						notify(ctx, "warn", "No repositories found")
						done({ changed_pr = false, message = "No repositories found" }, nil)
						return
					end

					notify(ctx, "info", string.format("Found %d repositories", #list), 1200)

					vim.ui.select(list, {
						prompt = "Select repository",
						kind = "atlas_bitbucket_repo_select",
						format_item = function(item)
							return item.full_name ~= "" and item.full_name or item.name
						end,
					}, function(repo)
						if repo == nil then
							done({ changed_pr = false, message = "Selection cancelled" }, nil)
							return
						end

						---@type AtlasBitbucketViewConfig
						local search_view = {
							name = "Search",
							key = nil,
							layout = "compact",
							repos = {
								{
									workspace = tostring(repo.owner or ""),
									repo = tostring(repo.repo_name or ""),
								},
							},
						}

						local controller = require("atlas.pulls.ui.main.controller")
						notify(
							ctx,
							"success",
							string.format("Search view -> %s", tostring(repo.full_name or repo.name))
						)
						controller.switch_view(search_view)
						done({ changed_pr = false, message = "Search view switched" }, nil)
					end)
				end)
			end)
		end

		if #ws == 1 then
			continue_with_workspace(ws[1])
			return
		end

		vim.ui.select(ws, {
			prompt = "Select workspace",
			kind = "atlas_bitbucket_workspace_select",
			format_item = function(item)
				return item.slug
			end,
		}, function(selected)
			if selected == nil then
				done({ changed_pr = false, message = "Selection cancelled" }, nil)
				return
			end
			continue_with_workspace(selected)
		end)
	end)
end

register({
	id = actions.request_changes.id,
	label = actions.request_changes.label,
	is_available = request_changes_available,
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

register({
	id = actions.decline.id,
	label = actions.decline.label,
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
	run = search,
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
