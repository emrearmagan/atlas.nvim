---@alias AtlasShortcutIssueActionId
---| AtlasIssueActionId
---| "reporter"
---| "labels"
---| "archive"
---| "unarchive"
---| "delete_issue"
---| "create_checklist_item"

local M = {}

local actions = require("atlas.issues.actions")
local checklist_api = require("atlas.issues.providers.shortcut.api.tasks")
local editor = require("atlas.ui.popups.editor")
local icons = require("atlas.ui.shared.icons")
local labels_api = require("atlas.issues.providers.shortcut.api.labels")
local users_api = require("atlas.providers.shortcut.users")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local stories_api = require("atlas.issues.providers.shortcut.api.stories")
local utils = require("atlas.issues.actions.utils")
local workflows_api = require("atlas.issues.providers.shortcut.api.workflows")

---@type AtlasIssueAction[]
local ACTIONS = {}
M.items = ACTIONS

---@param action AtlasIssueAction
local function register(action)
	table.insert(ACTIONS, action)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function has_issue(ctx)
	return ctx.issue ~= nil, "No Story selected"
end

---@param users ShortcutUser[]
---@return ShortcutUser[]
local function active_users(users)
	local active = {}
	for _, user in ipairs(users) do
		if not user.disabled then
			table.insert(active, user)
		end
	end
	return active
end

---@param issue Issue
---@param fields ShortcutStoryUpdate
---@param loading string
---@param success string
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function update_story(issue, fields, loading, success, done)
	notify.loading(loading)
	stories_api.update(issue, fields, function(ok, err)
		if not ok then
			notify.error(err or "Story update failed")
			done(nil, err or "Story update failed")
			return
		end
		notify.success(success, { timeout = 1200 })
		done({ issue_key = issue.key }, nil)
	end)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function transition(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue ShortcutIssue
	notify.loading("Loading workflow states...")
	workflows_api.list_states(function(states, err)
		if err or states == nil then
			local message = err or "Failed to load workflow states"
			notify.error(message)
			done(nil, message)
			return
		end

		local workflow_id
		for _, state in ipairs(states) do
			if state.id == issue.workflow_state_id then
				workflow_id = state.workflow_id
				break
			end
		end

		local items = {}
		for _, state in ipairs(states) do
			if state.workflow_id == workflow_id and state.id ~= issue.workflow_state_id then
				table.insert(items, state)
			end
		end
		table.sort(items, function(a, b)
			return a.position < b.position
		end)
		notify.clear()

		picker.select({
			title = string.format("Workflow state for #%s", issue.key),
			items = items,
			format_item = function(state)
				return state.name
			end,
			on_select = function(state)
				if state == nil then
					done(nil, nil)
					return
				end
				update_story(
					issue,
					{ workflow_state_id = state.id },
					string.format("Moving #%s...", issue.key),
					string.format("Moved #%s to %s", issue.key, state.name),
					done
				)
			end,
		})
	end)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function assign(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue ShortcutIssue
	notify.loading("Loading Shortcut members...")
	users_api.list(function(users, err)
		if err or users == nil then
			local message = err or "Failed to load members"
			notify.error(message)
			done(nil, message)
			return
		end
		---@cast users ShortcutUser[]
		local selected_ids = {}
		for _, id in ipairs(issue.owner_ids) do
			selected_ids[id] = true
		end
		local available = {}
		local selected = {}
		for _, user in ipairs(users) do
			if not user.disabled or selected_ids[user.id] then
				table.insert(available, user)
				if selected_ids[user.id] then
					table.insert(selected, user)
				end
			end
		end
		notify.clear()

		picker.multi_select({
			title = string.format("Owners for #%s", issue.key),
			items = available,
			selected = selected,
			key = function(user)
				return user.id
			end,
			format_item = function(user)
				return string.format("%s %s", icons.get("user"), user.name)
			end,
			on_done = function(chosen)
				local chosen_ids = {}
				local owner_ids = {}
				for _, user in ipairs(chosen) do
					chosen_ids[user.id] = true
					table.insert(owner_ids, user.id)
				end
				local adds, removes = utils.selection_diff(selected_ids, chosen_ids)
				if #adds == 0 and #removes == 0 then
					done(nil, nil)
					return
				end

				update_story(
					issue,
					{ owner_ids = owner_ids },
					string.format("Updating owners on #%s...", issue.key),
					string.format("Updated owners on #%s", issue.key),
					done
				)
			end,
		})
	end)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function reporter(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue ShortcutIssue
	notify.loading("Loading Shortcut members...")
	users_api.list(function(users, err)
		if err or users == nil then
			local message = err or "Failed to load members"
			notify.error(message)
			done(nil, message)
			return
		end
		---@cast users ShortcutUser[]
		users = active_users(users)
		notify.clear()

		picker.select({
			title = string.format("Requester for #%s", issue.key),
			items = users,
			format_item = function(user)
				return string.format("%s %s", icons.get("user"), user.name)
			end,
			on_select = function(user)
				if user == nil then
					done(nil, nil)
					return
				end
				if issue.reporter and issue.reporter.id == user.id then
					done(nil, nil)
					return
				end
				update_story(
					issue,
					{ requested_by_id = user.id },
					string.format("Updating requester on #%s...", issue.key),
					string.format("Updated requester on #%s", issue.key),
					done
				)
			end,
		})
	end)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function labels(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue ShortcutIssue
	notify.loading("Loading Shortcut labels...")
	labels_api.list(function(available, err)
		if err or available == nil then
			local message = err or "Failed to load labels"
			notify.error(message)
			done(nil, message)
			return
		end
		notify.clear()

		picker.multi_select({
			title = string.format("Labels for #%s", issue.key),
			items = available,
			selected = vim.deepcopy(issue.labels),
			key = function(label)
				return tostring(label.id)
			end,
			format_item = function(label)
				return label.name
			end,
			on_done = function(chosen)
				local before = {}
				local after = {}
				local inputs = {}
				for _, label in ipairs(issue.labels) do
					before[label.name] = true
				end
				for _, label in ipairs(chosen) do
					after[label.name] = true
					table.insert(inputs, { name = label.name })
				end
				local adds, removes = utils.selection_diff(before, after)
				if #adds == 0 and #removes == 0 then
					done(nil, nil)
					return
				end

				update_story(
					issue,
					{ labels = inputs },
					string.format("Updating labels on #%s...", issue.key),
					string.format("Updated labels on #%s", issue.key),
					done
				)
			end,
		})
	end)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function archive_available(ctx)
	if ctx.issue == nil then
		return false, "No Story selected"
	end
	return ctx.issue.status_id ~= "archived", "Story is already archived"
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function archive(ctx, done)
	local issue = assert(ctx.issue)
	update_story(
		issue,
		{ archived = true },
		string.format("Archiving #%s...", issue.key),
		string.format("Archived #%s", issue.key),
		done
	)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function unarchive_available(ctx)
	if ctx.issue == nil then
		return false, "No Story selected"
	end
	return ctx.issue.status_id == "archived", "Story is not archived"
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function unarchive(ctx, done)
	local issue = assert(ctx.issue)
	update_story(
		issue,
		{ archived = false },
		string.format("Unarchiving #%s...", issue.key),
		string.format("Unarchived #%s", issue.key),
		done
	)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function toggle_subscription(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue ShortcutIssue

	---@param user AtlasUser
	local function toggle(user)
		---@cast user ShortcutUser
		local following = false
		for _, id in ipairs(issue.follower_ids) do
			if id == user.id then
				following = true
				break
			end
		end

		local follower_ids = {}
		for _, id in ipairs(issue.follower_ids) do
			if not following or id ~= user.id then
				table.insert(follower_ids, id)
			end
		end
		if not following then
			table.insert(follower_ids, user.id)
		end

		notify.loading(following and "Unfollowing Story..." or "Following Story...")
		stories_api.update(issue, { follower_ids = follower_ids }, function(ok, err)
			if not ok then
				notify.error(err or "Follow update failed")
				done(nil, err or "Follow update failed")
				return
			end

			issue.is_subscribed = not following
			issue.follower_ids = follower_ids
			notify.success(issue.is_subscribed and "Following Story" or "Unfollowed Story", { timeout = 1200 })
			done({ issue_key = issue.key }, nil)
		end)
	end

	if ctx.current_user then
		toggle(ctx.current_user)
		return
	end
	users_api.fetch_user(function(user, err)
		if err or user == nil then
			local message = err or "Failed to load current member"
			notify.error(message)
			done(nil, message)
			return
		end
		toggle(user)
	end)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function delete_issue(ctx, done)
	local issue = assert(ctx.issue)
	vim.ui.input({ prompt = string.format("Delete Story #%s? [y/N]: ", issue.key) }, function(input)
		if input == nil or vim.trim(input):lower() ~= "y" then
			done(nil, nil)
			return
		end

		notify.loading(string.format("Deleting #%s...", issue.key))
		stories_api.delete(issue, function(ok, err)
			if not ok then
				notify.error(err or "Story deletion failed")
				done(nil, err or "Story deletion failed")
				return
			end
			notify.success(string.format("Deleted #%s", issue.key), { timeout = 1200 })
			done({ issue_key = issue.key, removed = true }, nil)
		end)
	end)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function create_checklist_item(ctx, done)
	local issue = assert(ctx.issue)
	editor.open({
		key = "shortcut-checklist-action-add-" .. tostring(issue.key),
		title = " Add Checklist Item ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		on_save = function(text)
			if vim.trim(text) == "" then
				done(nil, nil)
				return
			end

			notify.loading("Adding Checklist item...")
			checklist_api.create(issue, text, function(_, err)
				if err then
					notify.error("Add Checklist item failed: " .. err)
					done(nil, err)
					return
				end
				notify.success("Checklist item added", { timeout = 1200 })
				done({ issue_key = issue.key }, nil)
			end)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param _ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function create_issue(_ctx, done)
	return require("atlas.issues.providers.shortcut.ui.editor").open(function(result, err)
		done(result and { issue_key = result.key } or nil, err)
	end)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function edit_issue(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue ShortcutIssue
	return require("atlas.issues.providers.shortcut.ui.editor").edit(issue, function(result, err)
		done(result and { issue_key = issue.key } or nil, err)
	end)
end

---@param _ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function search(_ctx, done)
	picker.search({
		title = "Search Shortcut Stories",
		fetch_on_open = false,
		format_item = function(item)
			local issue = item.value
			return string.format("#%s %s", issue.key, issue.title)
		end,
		preview_item = function(item, preview_done)
			local issue = item.value
			return stories_api.get(issue.id, nil, function(details, err)
				if err or details == nil then
					preview_done({ title = "#" .. issue.key, lines = { err or "Failed to load Story" } })
					return
				end
				local story_description = vim.trim(details.description)
				preview_done({
					title = "#" .. issue.key,
					lines = vim.split(
						story_description ~= "" and story_description or "No description",
						"\n",
						{ plain = true }
					),
				})
			end)
		end,
		fetch = function(query, fetch_done)
			query = vim.trim(query)
			if query == "" then
				fetch_done({}, nil)
				return nil
			end
			return stories_api.search(query, { pagelen = 20 }, function(page, err)
				if err then
					fetch_done(nil, err)
					return
				end
				local items = {}
				for _, issue in ipairs(page.items) do
					table.insert(items, { id = issue.key, value = issue })
				end
				fetch_done(items, nil)
			end)
		end,
		on_select = function(item)
			local issue = item.value
			require("atlas.commands.open").open(issue.url)
			done(nil, nil)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

register({
	id = "transition",
	label = "Change Workflow State",
	icon = icons.get("transition", "actions"),
	is_available = has_issue,
	run = transition,
})
register({
	id = "assign",
	label = "Edit Owners",
	icon = icons.get("user", "actions"),
	is_available = has_issue,
	run = assign,
})
register({
	id = "reporter",
	label = "Change Requester",
	icon = icons.get("user", "actions"),
	is_available = has_issue,
	run = reporter,
})
register({
	id = "labels",
	label = "Edit Labels",
	icon = icons.get("label", "actions"),
	is_available = has_issue,
	run = labels,
})
register({
	id = "archive",
	label = "Archive Story",
	icon = icons.get("close", "actions"),
	is_available = archive_available,
	run = archive,
})
register({
	id = "unarchive",
	label = "Unarchive Story",
	icon = icons.get("reopen", "actions"),
	is_available = unarchive_available,
	run = unarchive,
})
register({
	id = "toggle_subscription",
	label = "Follow / Unfollow Story",
	icon = icons.get("notification", "actions"),
	is_available = has_issue,
	run = toggle_subscription,
})
register({
	id = "delete_issue",
	label = "Delete Story",
	icon = icons.get("delete", "actions"),
	is_available = has_issue,
	run = delete_issue,
})
register({
	id = "edit_issue",
	label = "Edit Story",
	icon = icons.get("edit", "actions"),
	is_available = has_issue,
	run = edit_issue,
})
register({ id = "create_issue", label = "Create Story", icon = icons.get("create", "actions"), run = create_issue })
register({
	id = "create_checklist_item",
	label = "Add Checklist Item",
	icon = icons.get("create", "actions"),
	is_available = has_issue,
	run = create_checklist_item,
})
register({ id = "search", label = "Search Stories", icon = icons.get("search", "actions"), run = search })
register({
	id = "edit_search",
	label = "Edit search",
	icon = icons.get("search", "actions"),
	run = function(_, done)
		local state = require("atlas.issues.state")
		require("atlas.providers.shortcut.completion.search").edit(state.query .. " ", function(query)
			local view = state.search_view()
			if view then
				view.search = query
				require("atlas.issues.ui.dashboard.controller").refresh_view()
			end
		end)
		done(nil, nil)
	end,
})
register(actions.manage_templates)
register(actions.browse_issue)
register(actions.copy_issue_key)
register(actions.copy_issue_url)

---@param id AtlasShortcutIssueActionId
---@return AtlasIssueAction|nil
function M.find(id)
	for _, action in ipairs(ACTIONS) do
		if action.id == id then
			return action
		end
	end
end

return M
