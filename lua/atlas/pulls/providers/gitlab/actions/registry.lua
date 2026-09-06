local M = {}

local actions = require("atlas.pulls.actions")
local action_utils = require("atlas.pulls.actions.utils")
local icons = require("atlas.ui.shared.icons")
local picker = require("atlas.ui.picker")
local core_notify = require("atlas.core.notify")
local notes = require("atlas.pulls.notes")
local pullrequests_api = require("atlas.pulls.providers.gitlab.api.pullrequests")
local users_api = require("atlas.pulls.providers.gitlab.api.users")
local service = require("atlas.providers.gitlab.client")

---@param ctx AtlasPullActionContext
---@return boolean
local function has_pr(ctx)
	return ctx.pr ~= nil
end

---@param pr PullRequest
---@return string
local function pr_label(pr)
	local path = pr.repo_full_name
	if path ~= "" then
		return string.format("%s!%s", path, tostring(pr.id or ""))
	end
	return string.format("!%s", tostring(pr.id or ""))
end

---@param ctx AtlasPullActionContext
---@return boolean
local function is_open_or_draft(ctx)
	return has_pr(ctx) and (ctx.pr.state == "open" or ctx.pr.state == "draft")
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
	if not is_open_or_draft(ctx) then
		return false, "MR is not open"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function merge_available(ctx)
	if not has_pr(ctx) then
		return false, "No MR selected"
	end
	if ctx.pr.state == "draft" then
		return false, "MR is a draft"
	end
	if ctx.pr.state ~= "open" then
		return false, "MR is not open"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function merge(ctx, done)
	local pr = ctx.pr
	local options = action_utils.merge_options()
	local label = options.method == "squash" and "squash merge" or "merge"
	vim.ui.input({ prompt = string.format("Confirm %s of %s? [y/N]: ", label, pr_label(pr)) }, function(input)
		if not input or not vim.trim(input):lower():match("^y") then
			done({ changed_pr = false, message = "Merge cancelled" }, nil)
			return
		end
		notify(ctx, "loading", string.format("Merging %s...", pr_label(pr)))
		pullrequests_api.merge(pr, {
			squash = options.method == "squash",
			should_remove_source_branch = options.delete_branch,
		}, function(ok, err)
			if not ok then
				notify(ctx, "error", err or "Merge failed")
				done(nil, err or "Merge failed")
				return
			end
			notify(ctx, "success", string.format("Merged %s", pr_label(pr)), 1500)
			notes.clear_for_pull_request(pr)
			done({ changed_pr = true, message = "Merged" }, nil)
		end)
	end)
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function reopen_available(ctx)
	if not has_pr(ctx) then
		return false, "No MR selected"
	end
	if ctx.pr.state ~= "declined" then
		return false, "MR is not closed"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function reopen(ctx, done)
	local pr = ctx.pr
	notify(ctx, "loading", string.format("Reopening %s...", pr_label(pr)))
	pullrequests_api.set_state(pr, "reopen", function(ok, err)
		if not ok then
			notify(ctx, "error", err or "Reopen failed")
			done(nil, err or "Reopen failed")
			return
		end
		notify(ctx, "success", string.format("Reopened %s", pr_label(pr)), 1200)
		done({ changed_pr = true, message = "Reopened" }, nil)
	end)
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function edit_assignees_available(ctx)
	if not is_open_or_draft(ctx) then
		return false, "MR is not open"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function edit_assignees(ctx, done)
	local pr = ctx.pr
	local path = pr.repo_full_name
	if path == "" then
		done(nil, "Could not determine project path")
		return
	end

	---@param assignees PullsAuthor[]
	local function open_picker(assignees)
		users_api.list_members(path, "", function(members, err)
			if err or members == nil then
				notify(ctx, "error", err or "Failed to load members")
				done(nil, err or "Failed to load members")
				return
			end
			if #members == 0 then
				notify(ctx, "warn", "No assignable members")
				done(nil, "No assignable members")
				return
			end
			notify(ctx, "success", "Members loaded", 1200)

			local original = {}
			local original_set = {}
			for _, a in ipairs(assignees) do
				local id = tonumber(a.id)
				if id then
					table.insert(original, { id = id, username = a.username, name = a.name or a.username })
					original_set[id] = true
				end
			end

			picker.multi_select({
				items = members,
				selected = vim.deepcopy(original),
				key = function(item)
					return tostring(item.id or "")
				end,
				format_item = function(item)
					return string.format(
						"%s %s (@%s)",
						icons.general("user"),
						item.name or item.username,
						item.username
					)
				end,
				title = string.format("Assignees for %s", pr_label(pr)),
				on_done = function(selected)
					local final_ids = {}
					local final_set = {}
					for _, it in ipairs(selected) do
						local id = tonumber(it.id)
						if id then
							table.insert(final_ids, id)
							final_set[id] = true
						end
					end

					local changed = false
					if #final_ids ~= #original then
						changed = true
					else
						for id, _ in pairs(original_set) do
							if not final_set[id] then
								changed = true
								break
							end
						end
					end

					if not changed then
						done({ changed_pr = false, message = "No changes" }, nil)
						return
					end

					notify(ctx, "loading", string.format("Updating assignees on %s...", pr_label(pr)))
					pullrequests_api.update_assignees(pr, final_ids, function(ok, set_err)
						if not ok then
							notify(ctx, "error", set_err or "Failed")
							done(nil, set_err or "Failed")
							return
						end
						local msg = string.format("%d assignee(s)", #final_ids)
						notify(ctx, "success", msg, 1200)
						done({ changed_pr = true, message = msg }, nil)
					end)
				end,
			})
		end)
	end

	notify(ctx, "loading", "Loading members...")
	if ctx.details then
		open_picker(ctx.details.assignees or {})
		return
	end
	pullrequests_api.fetch_pullrequest(pr, { force_refresh = false }, function(details, err)
		if err or details == nil then
			local message = tostring(err or "Failed to load merge request")
			notify(ctx, "error", message)
			done(nil, message)
			return
		end
		open_picker(details.assignees or {})
	end)
end

---@param opts {
--- title: string,
--- include_all: boolean,
--- on_select: fun(project: string),
--- on_cancel: fun(),
---}
local function select_project(opts)
	local initial_items = opts.include_all and { { id = "all", label = "All projects", project = "" } } or {}
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

			local endpoint =
				string.format("/projects?search=%s&per_page=20&order_by=last_activity_at", service.url_encode(query))
			return service.request("GET", endpoint, nil, function(result, err)
				if err then
					fetch_done(nil, tostring(err))
					return
				end

				local items = {}
				for _, project in ipairs(result) do
					local path = project.path_with_namespace
					table.insert(items, { id = path, label = path, project = path })
				end
				fetch_done(items, nil)
			end, {
				action = "Search projects",
				query = query,
			})
		end,
		on_select = function(item)
			opts.on_select(item.project)
		end,
		on_cancel = opts.on_cancel,
	})
end

---@param project string
---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function search_merge_requests(project, ctx, done)
	picker.search({
		title = project ~= "" and "Search " .. project .. " Merge Requests" or "Search GitLab Merge Requests",
		fetch_on_open = false,
		format_item = function(item)
			return item.label
		end,
		preview_item = function(item, preview_done)
			local pr = item.value
			return pullrequests_api.fetch_pullrequest(pr, nil, function(details, err)
				if err or details == nil then
					preview_done({ title = pr_label(pr), lines = { err or "Failed to load merge request" } })
					return
				end
				local reviewers = vim.tbl_map(function(user)
					return "@" .. user.username
				end, pr.reviewers or {})
				local assignees = vim.tbl_map(function(user)
					return "@" .. user.username
				end, details.assignees)
				local labels = vim.tbl_map(function(label)
					return label.name
				end, details.labels)
				local lines = {
					"**Status:** " .. pr.state,
					"**Author:** " .. pr.author.name,
					string.format("**Branches:** %s -> %s", pr.source.branch, pr.destination.branch),
				}
				if #reviewers > 0 then
					table.insert(lines, "**Reviewers:** " .. table.concat(reviewers, ", "))
				end
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
				preview_done({
					title = string.format("%s - %s", pr_label(pr), pr.title),
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

			---@type AtlasGitLabPullsViewConfig
			local view = { name = "Search", scope = "all", search = query }
			if project ~= "" then
				view.project = project
			end
			return pullrequests_api.fetch_pullrequests(view, {
				force_refresh = false,
				pagelen = 30,
				state = "all",
			}, function(page, err)
				if err then
					fetch_done(nil, err)
					return
				end
				local items = {}
				for _, pr in ipairs(page.items) do
					table.insert(items, {
						id = pr.repo_full_name .. "!" .. tostring(pr.id),
						label = string.format("%s - %s", pr_label(pr), pr.title),
						value = pr,
					})
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
	select_project({
		title = "Search Merge Requests - Project",
		include_all = true,
		on_select = function(project)
			search_merge_requests(project, ctx, done)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param _ AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function open_project(_, done)
	select_project({
		title = "Open Project",
		include_all = false,
		on_select = function(project)
			require("atlas").open("pulls", "gitlab", {
				initial_view = {
					name = "Search",
					layout = "compact",
					project = project,
					scope = "all",
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
	if not has_pr(ctx) then
		return false, "No MR selected"
	end
	local path = ctx.pr.repo_full_name
	if path == "" then
		return false, "Missing project path"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function toggle_subscription(ctx, done)
	local pr = ctx.pr
	local path = pr.repo_full_name
	local iid = tonumber(pr.id)
	if iid == nil then
		done(nil, "Invalid MR identifier")
		return
	end

	---@param details PullRequestDetails
	local function toggle(details)
		local action = details.is_subscribed == true and "unsubscribe" or "subscribe"
		local endpoint = string.format("/projects/%s/merge_requests/%d/%s", service.url_encode(path), iid, action)
		notify(ctx, "loading", details.is_subscribed and "Unsubscribing..." or "Subscribing...")
		service.request("POST", endpoint, nil, function(result, err)
			if err then
				notify(ctx, "error", tostring(err))
				done(nil, tostring(err))
				return
			end
			local subscribed = type(result) == "table" and result.subscribed
			if type(subscribed) ~= "boolean" then
				subscribed = action == "subscribe"
			end
			details.is_subscribed = subscribed == true
			notify(ctx, "success", details.is_subscribed and "Subscribed" or "Unsubscribed", 1200)
			done({
				changed_pr = true,
				message = details.is_subscribed and "Subscribed" or "Unsubscribed",
			}, nil)
		end, {
			action = action == "subscribe" and "Subscribe to MR" or "Unsubscribe from MR",
			project_path = path,
			iid = iid,
		})
	end

	if ctx.details then
		toggle(ctx.details)
		return
	end
	pullrequests_api.fetch_pullrequest(pr, { force_refresh = false }, function(details, fetch_err)
		if fetch_err or details == nil then
			local message = tostring(fetch_err or "Failed to load merge request")
			notify(ctx, "error", message)
			done(nil, message)
			return
		end
		toggle(details)
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
	label = "Merge MR",
	icon = icons.action("merge"),
	is_available = merge_available,
	run = merge,
})

register(actions.decline)
register(actions.convert_to_draft)
register(actions.ready_for_review)

register({
	id = "reopen",
	label = "Reopen MR",
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
	id = "search",
	label = "Search Merge Requests",
	icon = icons.action("search"),
	run = search,
})

register({
	id = "open_project",
	label = "Open Project",
	icon = icons.action("search"),
	run = open_project,
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

register(actions.copy_id)
register(actions.copy_url)
register(actions.open_in_browser)

---@param id AtlasGitLabActionId
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
