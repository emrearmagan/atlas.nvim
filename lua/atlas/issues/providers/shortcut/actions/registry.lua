local M = {}

local actions = require("atlas.issues.actions")
local checklist_api = require("atlas.issues.providers.shortcut.api.tasks")
local editor = require("atlas.ui.popups.editor")
local icons = require("atlas.ui.shared.icons")
local labels_api = require("atlas.issues.providers.shortcut.api.labels")
local members_api = require("atlas.issues.providers.shortcut.api.members")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local story_editor = require("atlas.issues.create.shortcut.issue")
local stories_api = require("atlas.issues.providers.shortcut.api.stories")
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

---@param owners ShortcutIssueUser[]
---@return string[]
local function ids_for_owners(owners)
	local ids = {}
	for _, owner in ipairs(owners) do
		table.insert(ids, owner.account_id)
	end
	return ids
end

---@param users ShortcutIssueUser[]
---@return ShortcutIssueUser[]
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

		picker.find({
			title = string.format("Workflow state for #%s", issue.key),
			items = items,
			key = function(state)
				return tostring(state.id)
			end,
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
	members_api.list(function(users, err)
		if err or users == nil then
			local message = err or "Failed to load members"
			notify.error(message)
			done(nil, message)
			return
		end
		---@cast users ShortcutIssueUser[]
		local selected_ids = {}
		for _, id in ipairs(issue.owner_ids) do
			selected_ids[id] = true
		end
		local available = {}
		local selected = {}
		for _, user in ipairs(users) do
			if not user.disabled or selected_ids[user.account_id] then
				table.insert(available, user)
				if selected_ids[user.account_id] then
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
				return user.account_id
			end,
			format_item = function(user)
				return string.format("%s %s", icons.general("user"), user.display_name)
			end,
			on_done = function(chosen)
				local owner_ids = ids_for_owners(chosen)
				if vim.deep_equal(issue.owner_ids, owner_ids) then
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
	members_api.list(function(users, err)
		if err or users == nil then
			local message = err or "Failed to load members"
			notify.error(message)
			done(nil, message)
			return
		end
		---@cast users ShortcutIssueUser[]
		users = active_users(users)
		notify.clear()

		picker.find({
			title = string.format("Requester for #%s", issue.key),
			items = users,
			key = function(user)
				return user.account_id
			end,
			format_item = function(user)
				return string.format("%s %s", icons.general("user"), user.display_name)
			end,
			on_select = function(user)
				if user == nil then
					done(nil, nil)
					return
				end
				if issue.reporter and issue.reporter.account_id == user.account_id then
					done(nil, nil)
					return
				end
				update_story(
					issue,
					{ requested_by_id = user.account_id },
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
					table.insert(before, label.name)
				end
				for _, label in ipairs(chosen) do
					table.insert(after, label.name)
					table.insert(inputs, { name = label.name })
				end
				if vim.deep_equal(before, after) then
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

	---@param user IssueUser
	local function toggle(user)
		---@cast user ShortcutIssueUser
		local following = false
		for _, id in ipairs(issue.follower_ids) do
			if id == user.account_id then
				following = true
				break
			end
		end

		local follower_ids = {}
		for _, id in ipairs(issue.follower_ids) do
			if not following or id ~= user.account_id then
				table.insert(follower_ids, id)
			end
		end
		if not following then
			table.insert(follower_ids, user.account_id)
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
	members_api.get_current(function(user, err)
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
	local story_type = "feature"
	---@cast story_type ShortcutStoryType
	story_editor.open(function(fields, submit_done)
		---@type ShortcutStoryCreate
		local payload = {
			name = fields.name,
			description = fields.description,
			story_type = fields.story_type,
			workflow_state_id = assert(fields.workflow_state_id),
			owner_ids = ids_for_owners(fields.owners),
		}
		return stories_api.create(payload, function(created, err)
			if err or created == nil then
				local message = err or "Story creation failed"
				submit_done(false, message)
				return
			end

			submit_done(true, nil)
			vim.schedule(function()
				notify.success(string.format("Created #%s", created.key), { timeout = 1200 })
				done({ issue_key = created.key }, nil)
				if created.url then
					require("atlas.commands.open").open(created.url)
				end
			end)
		end)
	end, {
		name = "",
		description = "",
		story_type = story_type,
		workflow_state_id = nil,
		workflow_state_name = nil,
		owners = {},
	}, function()
		done(nil, nil)
	end)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function edit_issue(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue ShortcutIssue

	notify.loading(string.format("Loading #%s...", issue.key))
	return stories_api.get(issue.id, { force_refresh = true }, function(details, err)
		if err or details == nil then
			local message = err or "Failed to load Story"
			notify.error(message)
			done(nil, message)
			return
		end
		notify.clear()
		---@cast details ShortcutIssueDetails
		local story_type = issue.type.name
		---@cast story_type ShortcutStoryType
		local owners = details.assignees
		---@cast owners ShortcutIssueUser[]

		story_editor.open(function(fields, submit_done)
			---@type ShortcutStoryUpdate
			local payload = {}
			if fields.name ~= issue.title then
				payload.name = fields.name
			end
			if fields.description ~= details.description then
				payload.description = fields.description
			end
			if fields.story_type ~= issue.type.name then
				payload.story_type = fields.story_type
			end
			if fields.workflow_state_id ~= issue.workflow_state_id then
				payload.workflow_state_id = fields.workflow_state_id
			end

			local next_owner_ids = ids_for_owners(fields.owners)
			if not vim.deep_equal(issue.owner_ids, next_owner_ids) then
				payload.owner_ids = next_owner_ids
			end

			if next(payload) == nil then
				submit_done(true, nil)
				done(nil, nil)
				return nil
			end

			return stories_api.update(issue, payload, function(ok, update_err)
				if not ok then
					local message = update_err or "Story update failed"
					submit_done(false, message)
					return
				end

				submit_done(true, nil)
				vim.schedule(function()
					notify.success(string.format("Updated #%s", issue.key), { timeout = 1200 })
					done({ issue_key = issue.key }, nil)
				end)
			end)
		end, {
			name = issue.title,
			description = details.description,
			story_type = story_type,
			workflow_state_id = issue.workflow_state_id,
			workflow_state_name = issue.status,
			owners = owners,
		}, function()
			done(nil, nil)
		end)
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

register({ id = "transition", label = "Change Workflow State", is_available = has_issue, run = transition })
register({ id = "assign", label = "Edit Owners", is_available = has_issue, run = assign })
register({ id = "reporter", label = "Change Requester", is_available = has_issue, run = reporter })
register({ id = "labels", label = "Edit Labels", is_available = has_issue, run = labels })
register({ id = "archive", label = "Archive Story", is_available = archive_available, run = archive })
register({ id = "unarchive", label = "Unarchive Story", is_available = unarchive_available, run = unarchive })
register({
	id = "toggle_subscription",
	label = "Follow / Unfollow Story",
	is_available = has_issue,
	run = toggle_subscription,
})
register({ id = "delete_issue", label = "Delete Story", is_available = has_issue, run = delete_issue })
register({ id = "edit_issue", label = "Edit Story", is_available = has_issue, run = edit_issue })
register({ id = "create_issue", label = "Create Story", run = create_issue })
register({
	id = "create_checklist_item",
	label = "Add Checklist Item",
	is_available = has_issue,
	run = create_checklist_item,
})
register({ id = "search", label = "Search Stories", run = search })
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
