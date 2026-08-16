local M = {}

local actions = require("atlas.pulls.actions")
local action_utils = require("atlas.pulls.actions.utils")
local notes = require("atlas.pulls.notes")
local picker = require("atlas.picker")
local pullrequests = require("atlas.pulls.providers.gitea.forgejo.api.pullrequests")
local repositories = require("atlas.pulls.providers.gitea.forgejo.api.repositories")
local statusline = require("atlas.ui.statusline")

---@param ctx AtlasPullActionContext
---@return boolean
local function has_pr(ctx)
	return type(ctx) == "table" and type(ctx.pr) == "table" and ctx.pr.id ~= nil
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function has_repository(ctx)
	if not has_pr(ctx) then
		return false, "No PR selected"
	end
	if not tostring(ctx.pr.repo_full_name or ""):match("^[^/]+/[^/]+$") then
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
	local current_id = type(ctx.current_user) == "table" and tostring(ctx.current_user.id or "") or ""
	local author_id = type(ctx.pr.author) == "table" and tostring(ctx.pr.author.id or "") or ""
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
	(ctx.notify or statusline.notify)(level, message, duration)
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

---@param prompt string
---@param cancelled_message string
---@param on_confirm fun()
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function confirm(prompt, cancelled_message, on_confirm, done)
	vim.ui.input({ prompt = prompt }, function(input)
		local answer = vim.trim(tostring(input or "")):lower()
		if answer ~= "y" and answer ~= "yes" then
			done({ changed_pr = false, message = cancelled_message }, nil)
			return
		end
		on_confirm()
	end)
end

---@type AtlasPullAction[]
local ACTIONS = {}
M.items = ACTIONS

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
		confirm(
			string.format("Confirm %s merge PR #%s? [y/N]: ", options.method, tostring(pr.id)),
			"Merge cancelled",
			function()
				notify(ctx, "loading", "Merging PR...")
				pullrequests.merge(pr, options, function(ok, err)
					if not ok then
						notify(ctx, "error", "Merge failed: " .. tostring(err))
						done(nil, tostring(err or "Merge failed"))
						return
					end
					notes.clear_for_pull_request(pr)
					notify(ctx, "success", "Merge succeeded", 1200)
					done({ changed_pr = true, message = "Merged" }, nil)
				end)
			end,
			done
		)
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
				local message = tostring(err or "Update branch failed")
				notify(ctx, "error", message)
				done(nil, message)
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
		pullrequests.list_assignees(pr.repo_full_name, function(users, err)
			if err then
				notify(ctx, "error", "Failed to load assignees: " .. tostring(err))
				done(nil, tostring(err))
				return
			end
			local original_set = selected_set(pr.assignees, function(user)
				return tostring(user.username or "")
			end)
			local items, selected = {}, {}
			for _, user in ipairs(users or {}) do
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
							notify(ctx, "error", tostring(update_err or "Update assignees failed"))
							done(nil, tostring(update_err or "Update assignees failed"))
							return
						end
						notify(ctx, "success", "Assignees updated", 1200)
						done({ changed_pr = true, message = "Assignees updated" }, nil)
					end)
				end,
			})
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
		pullrequests.list_labels(pr.repo_full_name, function(raw_labels, err)
			if err then
				notify(ctx, "error", "Failed to load labels: " .. tostring(err))
				done(nil, tostring(err))
				return
			end
			local raw_pr = type(pr._raw) == "table" and pr._raw or {}
			local original_set = {}
			for _, id in ipairs(type(raw_pr.label_ids) == "table" and raw_pr.label_ids or {}) do
				original_set[tostring(id)] = true
			end
			local items, selected = {}, {}
			for _, label in ipairs(raw_labels or {}) do
				local id = tostring(type(label) == "table" and label.id or "")
				local name = tostring(type(label) == "table" and label.name or "")
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
							notify(ctx, "error", tostring(update_err or "Update labels failed"))
							done(nil, tostring(update_err or "Update labels failed"))
							return
						end
						notify(ctx, "success", "Labels updated", 1200)
						done({ changed_pr = true, message = "Labels updated" }, nil)
					end)
				end,
			})
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
				notify(ctx, "error", "Reopen failed: " .. tostring(err))
				done(nil, tostring(err))
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
			title = "Search Forgejo repositories",
			fetch_on_open = false,
			format_item = function(item)
				return item.label
			end,
			fetch = function(query, fetch_done)
				return repositories.search(query, function(matches, err)
					local items = {}
					for _, repo in ipairs(matches or {}) do
						table.insert(items, { id = repo, label = repo })
					end
					fetch_done(err and nil or items, err)
				end)
			end,
			on_select = function(item)
				local search_view = { name = "Search", layout = "compact", repo = item.id }
				require("atlas").open("pulls", "gitea", { initial_view = search_view })
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
		require("atlas.pulls.providers.gitea.completion.search").open_global()
		done(nil, nil)
	end,
})

register({
	id = "toggle_subscription",
	label = "Toggle subscription",
	is_available = has_repository,
	run = function(ctx, done)
		local pr = assert(ctx.pr)
		local user = type(ctx.current_user) == "table" and tostring(ctx.current_user.username or "") or ""
		if user == "" then
			done(nil, "Missing current Forgejo user")
			return
		end
		local function update(current)
			local subscribed = current ~= true
			notify(ctx, "loading", subscribed and "Subscribing..." or "Unsubscribing...")
			pullrequests.set_subscription(pr, user, subscribed, function(ok, err)
				if not ok then
					notify(ctx, "error", tostring(err or "Subscription update failed"))
					done(nil, tostring(err or "Subscription update failed"))
					return
				end
				pr.is_subscribed = subscribed
				notify(ctx, "success", subscribed and "Subscribed" or "Unsubscribed", 1200)
				done({ changed_pr = true, message = subscribed and "Subscribed" or "Unsubscribed" }, nil)
			end)
		end
		if pr.is_subscribed ~= nil then
			update(pr.is_subscribed)
			return
		end
		notify(ctx, "loading", "Checking subscription...")
		pullrequests.subscription(pr, function(current, err)
			if err or current == nil then
				notify(ctx, "error", tostring(err or "Subscription check failed"))
				done(nil, tostring(err or "Subscription check failed"))
				return
			end
			update(current)
		end)
	end,
})

register(actions.open_pipelines)
register(actions.open_diff)
register(actions.checkout)
register(actions.copy_id)
register(actions.copy_url)
register(actions.open_in_browser)

---@param id AtlasForgejoActionId
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
