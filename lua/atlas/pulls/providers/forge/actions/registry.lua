local actions = require("atlas.pulls.actions")
local action_utils = require("atlas.pulls.actions.utils")
local logger = require("atlas.core.logger")
local notes = require("atlas.pulls.notes")
local picker = require("atlas.ui.picker")
local core_notify = require("atlas.core.notify")
local icons = require("atlas.ui.shared.icons")
local query = require("atlas.pulls.providers.forge.query")
local search_prompt = require("atlas.providers.forge.completion.search")

local M = {}

---@class ForgePullActionsRegistry : PullsActionsCapability
---@field items AtlasPullAction[]
---@field find fun(id: string): AtlasPullAction|nil

---@param provider_id "gitea"|"forgejo"
---@param repositories ForgeRepositoriesApi
---@return ForgePullActionsRegistry
function M.new(provider_id, pullrequests, repositories)
	local provider_name = provider_id == "gitea" and "Gitea" or "Forgejo"

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
		return pullrequests.get(assert(ctx.pr), { force_refresh = false }, on_done)
	end

	---@param opts { title: string, include_all: boolean, on_select: fun(repo: string), on_cancel: fun() }
	local function select_repository(opts)
		local initial_items = opts.include_all and { { id = "", label = "All repositories" } } or {}
		picker.search({
			title = opts.title,
			initial_items = initial_items,
			fetch_on_open = false,
			format_item = function(item)
				return item.label
			end,
			fetch = function(input, fetch_done)
				input = vim.trim(input)
				if input == "" then
					fetch_done(initial_items, nil)
					return
				end
				return repositories.search(input, function(matches, err)
					if err then
						fetch_done(nil, err)
						return
					end
					local items = {}
					for _, repo in ipairs(matches or {}) do
						table.insert(items, { id = repo, label = repo })
					end
					fetch_done(items, nil)
				end)
			end,
			on_select = function(item)
				opts.on_select(item.id)
			end,
			on_cancel = opts.on_cancel,
		})
	end

	---@param repo string
	---@param ctx AtlasPullActionContext
	---@param done fun(result: PullsActionResult|nil, err: string|nil)
	local function search_results(repo, ctx, done)
		picker.search({
			title = repo ~= "" and ("Search " .. repo .. " Pull Requests")
				or ("Search " .. provider_name .. " Pull Requests"),
			fetch_on_open = false,
			format_item = function(item)
				return item.label
			end,
			preview_item = function(item, preview_done)
				local pr = item.value
				return pullrequests.get(pr, { force_refresh = false }, function(details, err)
					if err or not details then
						preview_done({ title = item.label, lines = { err or "Failed to load pull request" } })
						return
					end
					local lines = { "**Status:** " .. pr.state, "**Author:** @" .. pr.author.username }
					local assignees, labels = {}, {}
					for _, user in ipairs(details.assignees or {}) do
						table.insert(assignees, "@" .. user.username)
					end
					for _, label in ipairs(details.labels or {}) do
						table.insert(labels, label.name)
					end
					if #assignees > 0 then
						table.insert(lines, "**Assignees:** " .. table.concat(assignees, ", "))
					end
					if #labels > 0 then
						table.insert(lines, "**Labels:** " .. table.concat(labels, ", "))
					end
					vim.list_extend(lines, { "", "## Description", "" })
					local description = vim.trim(details.description or "")
					vim.list_extend(
						lines,
						vim.split(description ~= "" and description or "No description", "\n", { plain = true })
					)
					preview_done({ title = item.label, lines = lines })
				end)
			end,
			fetch = function(input, fetch_done)
				input = vim.trim(input)
				if input == "" then
					fetch_done({}, nil)
					return
				end
				local view = { name = "Search" }
				local ok, err = query.apply(view, input, { "open", "merged", "declined" })
				if not ok then
					fetch_done(nil, err)
					return
				end
				view.repo = view.repo or repo
				local api_view, statuses = query.for_api(view)
				return pullrequests.search_global(
					api_view,
					statuses,
					{ force_refresh = false, pagelen = 30 },
					function(page, fetch_err)
						if fetch_err then
							fetch_done(nil, fetch_err)
							return
						end
						local items = {}
						for _, pr in ipairs(page.items) do
							local id = string.format("%s#%s", pr.repo_full_name, tostring(pr.id))
							table.insert(items, { id = id, label = id .. " - " .. pr.title, value = pr })
						end
						fetch_done(items, nil)
					end
				)
			end,
			on_select = function(item)
				local pr = item.value
				require("atlas.pulls.ui.detail").open(
					{ id = pr.id, repo_full_name = pr.repo_full_name },
					{ provider = ctx.provider }
				)
				done(nil, nil)
			end,
			on_cancel = function()
				done(nil, nil)
			end,
		})
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
		icon = actions.approve.icon,
		is_available = can_submit_review,
		run = actions.approve.run,
	})

	register({
		id = actions.request_changes.id,
		label = actions.request_changes.label,
		icon = actions.request_changes.icon,
		is_available = can_submit_review,
		run = actions.request_changes.run,
	})

	register({
		id = "merge",
		label = "Merge PR",
		icon = icons.action("merge"),
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
		icon = icons.action("checkout"),
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
		icon = icons.action("user"),
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
		icon = icons.action("label"),
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
		icon = icons.action("reopen"),
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
		label = "Search Pull Requests",
		icon = icons.action("search"),
		run = function(ctx, done)
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
		end,
	})

	register({
		id = "open_repo",
		label = "Open Repo",
		icon = icons.action("search"),
		run = function(_, done)
			select_repository({
				title = "Open " .. provider_name .. " Repo",
				include_all = false,
				on_select = function(repo)
					require("atlas").open(
						"pulls",
						provider_id,
						{ initial_view = { name = "Search", layout = "compact", repo = repo } }
					)
					done(nil, nil)
				end,
				on_cancel = function()
					done(nil, nil)
				end,
			})
		end,
	})

	register({
		id = "search_pull_requests",
		label = "Open Search View",
		icon = icons.action("search"),
		run = function(_, done)
			local state = require("atlas.pulls.state")
			local current = state.provider and state.provider.id == provider_id and state.search_view() or nil
			search_prompt.edit(
				provider_id,
				"pulls",
				current and (state.query .. " ") or "type:pulls is:open ",
				function(input)
					local view = { name = "Search", layout = current and current.layout or "compact" }
					local ok, err = query.apply(view, input)
					if not ok then
						core_notify.warn(err)
						return
					end
					if require("atlas.ui.dashboard").is_active("pulls", provider_id) then
						require("atlas.pulls.ui.dashboard.controller").switch_view(view)
					else
						require("atlas").open("pulls", provider_id, { initial_view = view })
					end
				end
			)
			done(nil, nil)
		end,
	})

	register({
		id = "edit_search",
		label = "Edit search",
		icon = icons.action("search"),
		is_available = function()
			local state = require("atlas.pulls.state")
			return state.provider ~= nil and state.provider.id == provider_id and state.search_view() ~= nil
		end,
		run = function(_, done)
			local state = require("atlas.pulls.state")
			local view = state.provider and state.provider.id == provider_id and state.search_view() or nil
			if view == nil then
				done(nil, nil)
				return
			end
			search_prompt.edit(provider_id, "pulls", state.query .. " ", function(input)
				if state.provider and state.provider.id == provider_id and state.search_view() == view then
					local ok, err = query.apply(view, input)
					if not ok then
						core_notify.warn(err)
						return
					end
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
