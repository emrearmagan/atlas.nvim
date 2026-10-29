---@alias AtlasGitLabActionId
---| AtlasPullActionId
---| "reopen"
---| "edit_assignees"
---| "toggle_subscription"
---| "open_project"

local actions = require("atlas.pulls.actions")
local icons = require("atlas.ui.shared.icons")
local picker = require("atlas.ui.picker")
local notify = require("atlas.core.notify")
local pullrequests_api = require("atlas.pulls.providers.gitlab.api.pullrequests")
local users_api = require("atlas.providers.gitlab.users")
local service = require("atlas.providers.gitlab.client")
local gitlab_query = require("atlas.providers.gitlab.query")
local gitlab_search = require("atlas.providers.gitlab.completion.search")

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

---@type AtlasPullAction[]
local ACTIONS = {}

---@param action AtlasPullAction
local function register(action)
	table.insert(ACTIONS, action)
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function project_available(ctx)
	if not has_pr(ctx) then
		return false, "No MR selected"
	end
	return ctx.pr.repo_full_name ~= "", "Missing project path"
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function assignees_available(ctx)
	local ok, err = project_available(ctx)
	if not ok then
		return ok, err
	end
	return ctx.pr.state == "open" or ctx.pr.state == "draft", "MR is not open"
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
	local pr = assert(ctx.pr)
	notify.loading(string.format("Reopening %s...", pr_label(pr)))
	pullrequests_api.set_state(pr, "reopen", function(ok, err)
		if not ok then
			notify.error(err or "Reopen failed")
			done(nil, err or "Reopen failed")
			return
		end
		notify.success(string.format("Reopened %s", pr_label(pr)), { timeout = 1200 })
		done({ changed_pr = true }, nil)
	end)
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function edit_assignees(ctx, done)
	local pr = assert(ctx.pr)
	local path = pr.repo_full_name

	---@param assignees AtlasUser[]
	local function open_picker(assignees)
		users_api.list_members(path, "", function(members, err)
			if err or members == nil then
				notify.error(err or "Failed to load members")
				done(nil, err or "Failed to load members")
				return
			end
			if #members == 0 then
				notify.warn("No assignable members")
				done(nil, "No assignable members")
				return
			end
			notify.success("Members loaded", { timeout = 1200 })

			local original = {}
			local original_set = {}
			for _, a in ipairs(assignees) do
				local id = tonumber(a.id)
				if id then
					table.insert(original, { id = tostring(id), username = a.username, name = a.name or a.username })
					original_set[id] = true
				end
			end

			picker.multi_select({
				items = members,
				selected = original,
				key = function(item)
					return tostring(item.id or "")
				end,
				format_item = function(item)
					return string.format(
						"%s %s%s",
						icons.get("user"),
						item.name,
						item.username and item.username ~= "" and (" (@" .. item.username .. ")") or ""
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
						done({ changed_pr = false }, nil)
						return
					end

					notify.loading(string.format("Updating assignees on %s...", pr_label(pr)))
					pullrequests_api.update_assignees(pr, final_ids, function(ok, set_err)
						if not ok then
							notify.error(set_err or "Failed")
							done(nil, set_err or "Failed")
							return
						end
						local msg = string.format("%d assignee(s)", #final_ids)
						notify.success(msg, { timeout = 1200 })
						done({ changed_pr = true }, nil)
					end)
				end,
			})
		end)
	end

	notify.loading("Loading members...")
	if ctx.details then
		open_picker(ctx.details.assignees or {})
		return
	end
	pullrequests_api.fetch_pullrequest(pr, { force_refresh = false }, function(details, err)
		if err or details == nil then
			local message = tostring(err or "Failed to load merge request")
			notify.error(message)
			done(nil, message)
			return
		end
		open_picker(details.assignees or {})
	end)
end

---@param opts {
--- title: string,
--- on_select: fun(project: string),
--- on_cancel: fun(),
---}
local function select_project(opts)
	picker.search({
		title = opts.title,
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

---@param pr PullRequest
---@param details GitLabPullRequestDetails
---@return string[]
local function search_preview(pr, details)
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
		"**Author:** @" .. pr.author.username,
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
	vim.list_extend(lines, vim.split(description ~= "" and description or "No description", "\n", { plain = true }))
	return lines
end

---@param project string
---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function search_merge_requests(project, ctx, done)
	picker.search({
		title = "Search " .. project .. " Merge Requests",
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
				---@cast details GitLabPullRequestDetails

				preview_done({
					title = string.format("%s - %s", pr_label(pr), pr.title),
					lines = search_preview(pr, details),
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
			local view = { name = "Search", project = project, scope = "all", search = query }
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
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function toggle_subscription(ctx, done)
	local pr = assert(ctx.pr)
	local path = pr.repo_full_name
	local iid = assert(tonumber(pr.id))

	---@param details PullRequestDetails
	local function toggle(details)
		notify.loading(details.is_subscribed and "Unsubscribing..." or "Subscribing...")
		pullrequests_api.set_subscription(path, iid, details.is_subscribed ~= true, function(subscribed, err)
			if err then
				notify.error(tostring(err))
				done(nil, tostring(err))
				return
			end
			details.is_subscribed = subscribed
			notify.success(details.is_subscribed and "Subscribed" or "Unsubscribed", { timeout = 1200 })
			done({ changed_pr = true }, nil)
		end)
	end

	if ctx.details then
		toggle(ctx.details)
		return
	end
	pullrequests_api.fetch_pullrequest(pr, { force_refresh = false }, function(details, fetch_err)
		if fetch_err or details == nil then
			local message = tostring(fetch_err or "Failed to load merge request")
			notify.error(message)
			done(nil, message)
			return
		end
		toggle(details)
	end)
end

register(actions.approve)
register(actions.request_changes)

register({
	id = "merge",
	label = "Merge MR",
	icon = icons.get("merge", "actions"),
	is_available = actions.merge.is_available,
	run = actions.merge.run,
})

register(actions.decline)
register(actions.convert_to_draft)
register(actions.ready_for_review)

register({
	id = "reopen",
	label = "Reopen MR",
	icon = icons.get("reopen", "actions"),
	is_available = reopen_available,
	run = reopen,
})

register(actions.edit_pr)
register(actions.edit_reviewers)

register({
	id = "edit_assignees",
	label = "Edit assignees",
	icon = icons.get("user", "actions"),
	is_available = assignees_available,
	run = edit_assignees,
})

register({
	id = "search",
	label = "Search Merge Requests",
	icon = icons.get("search", "actions"),
	run = search,
})

register({
	id = "open_project",
	label = "Open Project",
	icon = icons.get("search", "actions"),
	run = open_project,
})

register(actions.browse_repository)
register({
	id = "browse_repositories",
	label = "Browse Repository",
	icon = icons.get("overview"),
	run = function(ctx, done)
		select_project({
			title = "Browse Repository",
			on_select = function(project)
				require("atlas.ui.repository").open(project, ctx.provider, { page = ctx.page })
				done(nil, nil)
			end,
			on_cancel = function()
				done(nil, nil)
			end,
		})
	end,
})

register({
	id = "edit_search",
	label = "Edit Current Search",
	icon = icons.get("search", "actions"),
	run = function(_, done)
		local state = require("atlas.pulls.state")
		gitlab_search.edit("pulls", state.query, function(query)
			local view = state.search_view()
			if view == nil then
				return
			end
			---@cast view AtlasGitLabPullsViewConfig
			local ok, err = gitlab_query.apply(view, query)
			if not ok then
				notify.warn(err)
				return
			end
			require("atlas.pulls.ui.dashboard.controller").refresh_view()
		end)
		done(nil, nil)
	end,
})

register({
	id = "toggle_subscription",
	label = "Toggle subscription",
	icon = icons.get("notification", "actions"),
	is_available = project_available,
	run = toggle_subscription,
})

register(actions.open_pipelines)
register(actions.open_diff)
register(actions.checkout)

register(actions.copy_id)
register(actions.copy_url)
register(actions.open_in_browser)

return ACTIONS
