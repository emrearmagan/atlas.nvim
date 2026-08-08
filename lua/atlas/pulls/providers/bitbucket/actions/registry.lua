local M = {}

local pullrequests = require("atlas.pulls.providers.bitbucket.api.pullrequests")
local users_api = require("atlas.pulls.providers.bitbucket.api.users")
local repositories = require("atlas.pulls.providers.bitbucket.api.repositories")
local statusline = require("atlas.ui.statusline")
local checkout = require("atlas.core.git.checkout")
local logger = require("atlas.core.logger")

---@class BitbucketActionContext
---@field pr PullRequest|nil
---@field source "main"|"panel"|"diff"|nil
---@field current_user PullsUser|nil
---@field notify fun(level: "loading"|"success"|"info"|"warn"|"error", message: string, duration: integer|nil)|nil

---@class BitbucketActionDef
---@field id BitbucketActionId|string
---@field label string
---@field is_available fun(ctx: BitbucketActionContext): boolean, string|nil
---@field run fun(ctx: BitbucketActionContext, done: fun(result: PullsActionResult|nil, err: string|nil))

---@param ctx BitbucketActionContext
---@return boolean
local function has_pr(ctx)
	return ctx.pr ~= nil and ctx.pr.id ~= nil
end

---@param pr PullRequest
---@param current_user PullsUser
---@return boolean
local function is_approved(pr, current_user)
	for _, participant in ipairs(pr._raw.participants or {}) do
		local user = participant.user or {}
		if tostring(user.account_id or user.uuid or "") == current_user.id then
			return participant.approved == true or participant.state == "approved"
		end
	end
	return false
end

---@param ctx BitbucketActionContext
---@param level "loading"|"success"|"warn"|"error"|"info"
---@param message string
---@param duration integer|nil
local function notify(ctx, level, message, duration)
	local callback = ctx.notify or statusline.notify
	callback(level, message, duration)
end

---@type BitbucketActionDef[]
local ACTIONS = {
	{
		id = "toggle_approval",
		label = "Approve / Unapprove",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			if not pullrequests.has_action(ctx.pr, "approve") then
				return false, "No approve URL available"
			end
			return true, nil
		end,
		run = function(ctx, done)
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
				local update = approved and pullrequests.unapprove or pullrequests.approve
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
		end,
	},
	{
		id = "request_changes",
		label = "Request changes",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			if not pullrequests.has_action(ctx.pr, "request_changes") then
				return false, "No request changes URL available"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			if pr == nil then
				done(nil, "No PR selected")
				return
			end

			notify(ctx, "loading", "Requesting changes...")
			pullrequests.request_changes(pr, function(_, err)
				if err ~= nil then
					notify(ctx, "error", string.format("Request changes failed: %s", tostring(err)))
					done(nil, tostring(err))
					return
				end

				notify(ctx, "success", "Changes requested", 1200)
				done({ changed_pr = true, message = "Changes requested" }, nil)
			end)
		end,
	},
	{
		id = "merge",
		label = "Merge",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			if not pullrequests.has_action(ctx.pr, "merge") then
				return false, "No merge URL available"
			end
			return true, nil
		end,
		run = function(ctx, done)
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
					statusline.notify("info", "Merge cancelled")
					done({ changed_pr = false, message = "Merge cancelled" }, nil)
					return
				end

				statusline.notify("loading", "Starting Merge...")
				pullrequests.merge(pr, {}, function(_, err)
					if err ~= nil then
						statusline.notify("error", string.format("Merge failed: %s", tostring(err)))
						done(nil, tostring(err))
						return
					end

					statusline.notify("success", "Merge succeeded", 1200)
					done({ changed_pr = true, message = "Merged" }, nil)
				end)
			end)
		end,
	},
	{
		id = "edit_title",
		label = "Edit title",
		is_available = function(ctx)
			return has_pr(ctx), "No PR selected"
		end,
		run = function(ctx, done)
			require("atlas.pulls.actions").edit_title(ctx.pr, pullrequests.update_title, function(changed)
				done({ changed_pr = changed, message = changed and "Title updated" or nil }, nil)
			end)
		end,
	},
	{
		id = "search",
		label = "Search repositories",
		is_available = function(_)
			return true, nil
		end,
		run = function(_, done)
			statusline.notify("loading", "Loading workspaces...")
			users_api.fetch_workspaces(function(workspaces, err)
				if err ~= nil then
					statusline.notify("error", string.format("Failed loading workspaces: %s", tostring(err)))
					done(nil, tostring(err))
					return
				end

				local ws = workspaces or {}
				if #ws == 0 then
					statusline.notify("warn", "No workspaces found")
					done({ changed_pr = false, message = "No workspaces found" }, nil)
					return
				end

				statusline.notify("info", string.format("Loaded %d workspaces", #ws), 1200)

				local function continue_with_workspace(selected_ws)
					if type(selected_ws) ~= "table" or tostring(selected_ws.slug or "") == "" then
						statusline.notify("warn", "Invalid workspace selection")
						done({ changed_pr = false, message = "Invalid workspace" }, nil)
						return
					end

					vim.ui.input({ prompt = string.format("Search repos in %s: ", selected_ws.slug) }, function(input)
						if input == nil then
							done({ changed_pr = false, message = "Search cancelled" }, nil)
							return
						end

						statusline.notify("loading", "Searching repositories...")
						repositories.fetch_workspace_repositories(selected_ws.slug, input, function(repos, repo_err)
							if repo_err ~= nil then
								statusline.notify("error", string.format("Repo search failed: %s", tostring(repo_err)))
								done(nil, tostring(repo_err))
								return
							end

							local list = repos or {}
							if #list == 0 then
								statusline.notify("warn", "No repositories found")
								done({ changed_pr = false, message = "No repositories found" }, nil)
								return
							end

							statusline.notify("info", string.format("Found %d repositories", #list), 1200)

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
								statusline.notify(
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
		end,
	},
}

---@param ctx BitbucketActionContext
---@return BitbucketActionDef[]
function M.available(ctx)
	local pulls_cfg = require("atlas.config").options.pulls or {}
	local custom_actions = pulls_cfg.custom_actions or {}

	local out = {}

	-- Add built-in actions
	for _, action in ipairs(ACTIONS) do
		if action.is_available(ctx) then
			table.insert(out, action)
		end
	end

	-- Add shared actions
	if has_pr(ctx) then
		local shared_actions = require("atlas.pulls.actions")
		table.insert(out, {
			id = "open_pipelines",
			label = "Open Pipelines",
			is_available = function()
				return true, nil
			end,
			run = function(action_ctx, done)
				shared_actions.open_pipelines(action_ctx.pr, done)
			end,
		})
		table.insert(out, {
			id = "open_diff",
			label = "Open diff",
			is_available = function()
				return true, nil
			end,
			run = function(action_ctx, done)
				shared_actions.open_diff(action_ctx.pr)
				done({ changed_pr = false, message = "Opened diff" }, nil)
			end,
		})
		table.insert(out, {
			id = "checkout",
			label = "Checkout PR branch",
			is_available = function()
				return true, nil
			end,
			run = function(action_ctx, done)
				shared_actions.checkout(action_ctx.pr)
				done({ changed_pr = false, message = "Checkout started" }, nil)
			end,
		})
	end

	-- Add custom actions
	for _, item in ipairs(custom_actions) do
		if type(item) == "table" and type(item.label) == "string" and type(item.run) == "function" then
			table.insert(out, {
				id = tostring(item.id or item.label),
				label = item.label,
				is_available = function(action_ctx)
					if not has_pr(action_ctx) then
						return false, "No PR selected"
					end
					return true, nil
				end,
				run = function(action_ctx, done)
					statusline.notify("loading", string.format("Running %s...", tostring(item.label)))

					local done_called = false
					local function custom_done(ok, message)
						if done_called then
							return
						end
						done_called = true

						vim.schedule(function()
							if ok == false then
								statusline.notify("error", tostring(message or (item.label .. " failed")))
								logger.logerror(string.format("Custom action failed: %s", tostring(message)))
								done(nil, tostring(message or (item.label .. " failed")))
								return
							end
							statusline.notify("success", tostring(message or (item.label .. " done")))
							done({ changed_pr = false, message = tostring(message or (item.label .. " done")) }, nil)
						end)
					end

					local repo_path = checkout.resolve_repo_path_for_pr(action_ctx.pr, {
						require_git = false,
						require_existing = false,
					})

					local pulls_state = require("atlas.pulls.state")
					local ok, err = pcall(item.run, action_ctx.pr, {
						repo_path = repo_path,
						pr = action_ctx.pr,
						user = pulls_state.current_user,
					}, custom_done)

					if not ok then
						custom_done(false, string.format("Custom action failed: %s", tostring(err)))
						logger.logerror(
							string.format("Custom action '%s' execution error: %s", item.label, tostring(err))
						)
					end
				end,
			})
		end
	end

	return out
end

---@param id BitbucketActionId|string
---@return BitbucketActionDef|nil
function M.find(id)
	for _, action in ipairs(ACTIONS) do
		if action.id == id then
			return action
		end
	end
	return nil
end

return M
