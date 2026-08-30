local actions = require("atlas.pulls.actions")
local action_utils = require("atlas.pulls.actions.utils")
local logger = require("atlas.core.logger")
local notes = require("atlas.pulls.notes")
local picker = require("atlas.ui.picker")
local core_notify = require("atlas.core.notify")

local M = {}

---@class ForgePullActionsRegistry : PullsActionsCapability
---@field items AtlasPullAction[]
---@field find fun(id: string): AtlasPullAction|nil

---@param provider_id "gitea"|"forgejo"
---@param pullrequests ForgePullRequestsApi
---@param repositories ForgeRepositoriesApi
---@return ForgePullActionsRegistry
function M.new(provider_id, pullrequests, repositories)
	local provider_name = provider_id == "gitea" and "Gitea" or "Forgejo"
	local search = require("atlas.pulls.providers.forge.completion.search").new(provider_id)

	---@param ctx AtlasPullActionContext
	---@return boolean, string|nil
	local function has_repository(ctx)
		if not ctx.pr then
			return false, "No PR selected"
		end
		if not ctx.pr.repo_full_name:match("^[^/]+/[^/]+$") then
			return false, "Missing repository info"
		end
		return true, nil
	end

	---@param ctx AtlasPullActionContext
	---@return boolean, string|nil
	local function can_review(ctx)
		local ok, err = has_repository(ctx)
		if not ok then
			return false, err
		end
		if ctx.pr.state ~= "open" and ctx.pr.state ~= "draft" then
			return false, "PR is not open"
		end
		return true, nil
	end

	---@param ctx AtlasPullActionContext
	---@return boolean, string|nil
	local function can_submit_review(ctx)
		local ok, err = can_review(ctx)
		if not ok then
			return false, err
		end
		local current_id = ctx.current_user and ctx.current_user.id or ""
		local author_id = ctx.pr.author.id
		if current_id ~= "" and current_id == author_id then
			return false, "Cannot review your own pull request"
		end
		return true, nil
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

	---@param values table[]|nil
	---@param key fun(value: table): string
	---@return table<string, boolean>
	local function selected_set(values, key)
		local result = {}
		for _, value in ipairs(values or {}) do
			local id = key(value)
			if id ~= "" then
				result[id] = true
			end
		end
		return result
	end

	---@param ctx AtlasPullActionContext
	---@param on_done fun(details: GiteaPullRequestDetails|ForgejoPullRequestDetails|nil, err: string|nil)
	---@return { cancel: fun() }|nil
	local function with_details(ctx, on_done)
		if ctx.details then
			local details = ctx.details
			---@cast details GiteaPullRequestDetails|ForgejoPullRequestDetails
			on_done(details, nil)
			return nil
		end
		return pullrequests.get(assert(ctx.pr), { force_load = false }, on_done)
	end

	---@type AtlasPullAction[]
	local ACTIONS = {}
	---@type ForgePullActionsRegistry
	local registry = { items = ACTIONS }

	---@param action AtlasPullAction
	local function register(action)
		table.insert(ACTIONS, action)
	end

	register({
		id = actions.approve.id,
		label = actions.approve.label,
		is_available = can_submit_review,
		run = actions.approve.run,
	})

	register({
		id = actions.request_changes.id,
		label = actions.request_changes.label,
		is_available = can_submit_review,
		run = actions.request_changes.run,
	})

	register({
		id = "merge",
		label = "Merge PR",
		is_available = function(ctx)
			local ok, err = has_repository(ctx)
			if not ok then
				return false, err
			end
			if ctx.pr.state == "draft" then
				return false, "PR is a draft"
			end
			if ctx.pr.state ~= "open" then
				return false, "PR is not open"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = assert(ctx.pr)
			local options = action_utils.merge_options()
			vim.ui.input({
				prompt = string.format("Confirm %s merge PR #%s? [y/N]: ", options.method, tostring(pr.id)),
			}, function(input)
				local answer = vim.trim(tostring(input or "")):lower()
				if answer ~= "y" and answer ~= "yes" then
					done({ changed_pr = false, message = "Merge cancelled" }, nil)
					return
				end
				notify(ctx, "loading", "Merging PR...")
				pullrequests.merge(pr, options, function(ok, err)
					if not ok then
						notify(ctx, "error", "Merge failed: " .. err)
						done(nil, err)
						return
					end
					notes.clear_for_pull_request(pr)
					notify(ctx, "success", "Merge succeeded", 1200)
					done({ changed_pr = true, message = "Merged" }, nil)
				end)
			end)
		end,
	})

	register({
		id = "update_branch",
		label = "Update branch",
		is_available = can_review,
		run = function(ctx, done)
			local pr = assert(ctx.pr)
			notify(ctx, "loading", "Updating branch...")
			pullrequests.update_branch(pr, "merge", function(ok, err)
				if not ok then
					notify(ctx, "error", err)
					done(nil, err)
					return
				end
				notify(ctx, "success", "Branch updated", 1200)
				done({ changed_pr = true, message = "Branch updated" }, nil)
			end)
		end,
	})

	register(actions.edit_title)
	register(actions.edit_description)
	register(actions.ready_for_review)
	register(actions.convert_to_draft)

	register({
		id = "edit_assignees",
		label = "Edit assignees",
		is_available = has_repository,
		run = function(ctx, done)
			local pr = assert(ctx.pr)
			notify(ctx, "loading", "Loading assignees...")
			with_details(ctx, function(details, details_err)
				if details_err or not details then
					local err = details_err or ("Failed to load " .. provider_name .. " pull request")
					notify(ctx, "error", "Failed to load pull request: " .. err)
					done(nil, err)
					return
				end
				pullrequests.list_assignees(pr.repo_full_name, function(users, err)
					if err then
						notify(ctx, "error", "Failed to load assignees: " .. err)
						done(nil, err)
						return
					end
					local original_set = selected_set(details.assignees, function(user)
						return user.username
					end)
					local items, selected = {}, {}
					for _, user in ipairs(users) do
						if user.username ~= "unknown" then
							table.insert(items, user)
							if original_set[user.username] then
								table.insert(selected, user)
							end
						end
					end
					if #items == 0 then
						done({ changed_pr = false, message = "No assignees available" }, nil)
						return
					end
					notify(ctx, "success", "Assignees loaded", 1200)
					picker.multi_select({
						items = items,
						selected = selected,
						key = function(user)
							return user.username
						end,
						format_item = function(user)
							return "@" .. user.username .. (user.name ~= user.username and (" — " .. user.name) or "")
						end,
						title = string.format("Assignees for PR #%s", tostring(pr.id)),
						on_done = function(chosen)
							local logins = {}
							for _, user in ipairs(chosen) do
								table.insert(logins, user.username)
							end
							local chosen_set = selected_set(chosen, function(user)
								return user.username
							end)
							if vim.deep_equal(chosen_set, original_set) then
								done({ changed_pr = false, message = "No changes" }, nil)
								return
							end
							notify(ctx, "loading", "Updating assignees...")
							pullrequests.update_assignees(pr, logins, function(ok, update_err)
								if not ok then
									notify(ctx, "error", update_err)
									done(nil, update_err)
									return
								end
								notify(ctx, "success", "Assignees updated", 1200)
								done({ changed_pr = true, message = "Assignees updated" }, nil)
							end)
						end,
					})
				end)
			end)
		end,
	})

	register({
		id = "labels",
		label = "Edit labels",
		is_available = has_repository,
		run = function(ctx, done)
			local pr = assert(ctx.pr)
			notify(ctx, "loading", "Loading labels...")
			with_details(ctx, function(details, details_err)
				if details_err or not details then
					local err = details_err or ("Failed to load " .. provider_name .. " pull request")
					notify(ctx, "error", "Failed to load pull request: " .. err)
					done(nil, err)
					return
				end
				pullrequests.list_labels(pr.repo_full_name, function(raw_labels, err)
					if err then
						notify(ctx, "error", "Failed to load labels: " .. err)
						done(nil, err)
						return
					end
					local original_set = {}
					for _, id in ipairs(details.label_ids or {}) do
						original_set[tostring(id)] = true
					end
					local items, selected = {}, {}
					for _, label in ipairs(raw_labels) do
						local id = tostring(label.id or "")
						local name = tostring(label.name or "")
						if id:match("^%d+$") and name ~= "" then
							local item = { id = id, name = name }
							table.insert(items, item)
							if original_set[id] then
								table.insert(selected, item)
							end
						end
					end
					if #items == 0 then
						done({ changed_pr = false, message = "No labels available" }, nil)
						return
					end
					notify(ctx, "success", "Labels loaded", 1200)
					picker.multi_select({
						items = items,
						selected = selected,
						key = function(label)
							return label.id
						end,
						format_item = function(label)
							return label.name
						end,
						title = string.format("Labels for PR #%s", tostring(pr.id)),
						on_done = function(chosen)
							local chosen_set = selected_set(chosen, function(label)
								return label.id
							end)
							if vim.deep_equal(chosen_set, original_set) then
								done({ changed_pr = false, message = "No changes" }, nil)
								return
							end
							local ids = {}
							for _, label in ipairs(chosen) do
								table.insert(ids, assert(tonumber(label.id)))
							end
							notify(ctx, "loading", "Updating labels...")
							pullrequests.update_labels(pr, ids, function(ok, update_err)
								if not ok then
									notify(ctx, "error", update_err)
									done(nil, update_err)
									return
								end
								notify(ctx, "success", "Labels updated", 1200)
								done({ changed_pr = true, message = "Labels updated" }, nil)
							end)
						end,
					})
				end)
			end)
		end,
	})

	register(actions.decline)

	register({
		id = "reopen",
		label = "Reopen PR",
		is_available = function(ctx)
			local ok, err = has_repository(ctx)
			if not ok then
				return false, err
			end
			if ctx.pr.state ~= "declined" then
				return false, "PR is not closed"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = assert(ctx.pr)
			notify(ctx, "loading", "Reopening PR...")
			pullrequests.set_state(pr, "open", function(_, err)
				if err then
					notify(ctx, "error", "Reopen failed: " .. err)
					done(nil, err)
					return
				end
				notify(ctx, "success", "PR reopened", 1200)
				done({ changed_pr = true, message = "Reopened" }, nil)
			end)
		end,
	})

	register(actions.edit_reviewers)

	register({
		id = "search",
		label = "Search repositories",
		run = function(ctx, done)
			picker.search({
				title = "Search " .. provider_name .. " repositories",
				fetch_on_open = false,
				format_item = function(item)
					return item.label
				end,
				fetch = function(query, fetch_done)
					return repositories.search(query, function(matches, err)
						if err then
							fetch_done(nil, err)
							return
						end
						local items = {}
						for _, repo in ipairs(matches) do
							table.insert(items, { id = repo, label = repo })
						end
						fetch_done(items, nil)
					end)
				end,
				on_select = function(item)
					local view = { name = "Search", layout = "compact", repo = item.id }
					require("atlas").open("pulls", provider_id, { initial_view = view })
					notify(ctx, "success", string.format("Search view -> %s", item.id), 1200)
					done({ changed_pr = false, message = "Search view switched" }, nil)
				end,
				on_cancel = function()
					done({ changed_pr = false, message = "Search cancelled" }, nil)
				end,
			})
		end,
	})

	register({
		id = "search_pull_requests",
		label = "Search pull requests",
		run = function(_, done)
			search.open_global()
			done(nil, nil)
		end,
	})

	register({
		id = "toggle_subscription",
		label = "Toggle subscription",
		is_available = has_repository,
		run = function(ctx, done)
			local pr = assert(ctx.pr)
			local details = ctx.details
			local user = ctx.current_user and ctx.current_user.username or ""
			local function update(current, username)
				local subscribed = current ~= true
				notify(ctx, "loading", subscribed and "Subscribing..." or "Unsubscribing...")
				pullrequests.set_subscription(pr, username, subscribed, function(ok, err)
					if not ok then
						notify(ctx, "error", err)
						done(nil, err)
						return
					end
					if details then
						details.is_subscribed = subscribed
					end
					notify(ctx, "success", subscribed and "Subscribed" or "Unsubscribed", 1200)
					done({ changed_pr = true, message = subscribed and "Subscribed" or "Unsubscribed" }, nil)
				end)
			end
			local function resolve_user(current)
				if user ~= "" then
					update(current, user)
					return
				end
				pullrequests.fetch_user(function(current_user, err)
					local username = current_user and current_user.username or ""
					if err or username == "" then
						local message = tostring(err or ("Missing current " .. provider_name .. " user"))
						notify(ctx, "error", message)
						done(nil, message)
						return
					end
					update(current, username)
				end)
			end
			if details and details.is_subscribed ~= nil then
				resolve_user(details.is_subscribed)
				return
			end
			notify(ctx, "loading", "Checking subscription...")
			pullrequests.subscription(pr, function(current, err)
				if err then
					notify(ctx, "error", err)
					done(nil, err)
					return
				end
				resolve_user(current)
			end)
		end,
	})

	register(actions.open_pipelines)
	register(actions.open_diff)
	register(actions.checkout)
	register(actions.copy_id)
	register(actions.copy_url)
	register(actions.open_in_browser)

	---@param id string
	---@return AtlasPullAction|nil
	function registry.find(id)
		for _, action in ipairs(ACTIONS) do
			if action.id == id then
				return action
			end
		end
		return nil
	end

	function registry.is_available(id, ctx)
		local action = registry.find(id)
		return action ~= nil and (action.is_available == nil or action.is_available(ctx) == true)
	end

	function registry.run(id, ctx, on_done)
		local action = registry.find(id)
		if action == nil then
			local err = string.format("Unknown action: %s", id)
			logger.logerror(provider_id .. ".pulls.action.unknown", { action_id = id })
			on_done(nil, err)
			return false
		end

		local available, available_err = true, nil
		if action.is_available then
			available, available_err = action.is_available(ctx)
		end
		if not available then
			local err = available_err or string.format("Action is not available: %s", id)
			logger.logwarn(provider_id .. ".pulls.action.unavailable", { action_id = id, error = err })
			if ctx.notify then
				ctx.notify("warn", err)
			else
				core_notify.warn(err)
			end
			on_done(nil, err)
			return false
		end

		action.run(ctx, on_done)
		return true
	end

	return registry
end

return M
