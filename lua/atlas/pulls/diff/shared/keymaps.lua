local M = {}

local comments = require("atlas.pulls.diff.shared.comments")
local notes = require("atlas.pulls.diff.shared.notes")
local resolver = require("atlas.core.keymaps")

---@class AtlasReviewKeymapDefinition
---@field action AtlasKeymapActionId
---@field desc string
---@field index integer
---@field callback fun()

---@class AtlasReviewKeymapGroup
---@field name string
---@field index integer
---@field items AtlasReviewKeymapDefinition[]

---@class AtlasReviewKeymapGroupOptions
---@field include_actions boolean|nil
---@field include_task boolean|nil
---@field reload (fun())|nil

---@class AtlasReviewKeymapOptions
---@field buffers integer[]
---@field reload (fun())|nil

---@param items AtlasReviewKeymapDefinition[]
---@param action AtlasKeymapActionId
---@param desc string
---@param index integer
---@param callback fun()|nil
local function add(items, action, desc, index, callback)
	if callback then
		table.insert(items, { action = action, desc = desc, index = index, callback = callback })
	end
end

---@param session AtlasReviewSession
---@param buf integer
local function open_item(session, buf)
	local has_comments = comments.has_at_cursor(session, buf)
	local has_notes = notes.has_at_cursor(session, buf)
	if has_comments and has_notes then
		vim.ui.select({ "Comment thread", "Local notes" }, { prompt = "Open review item:" }, function(choice)
			if choice == "Comment thread" then
				comments.open_at_cursor(session, buf)
			elseif choice == "Local notes" then
				notes.open_at_cursor(session, buf)
			end
		end)
	elseif has_comments then
		comments.open_at_cursor(session, buf)
	elseif has_notes then
		notes.open_at_cursor(session, buf)
	else
		session.review_view.notify("info", "No comment or note at cursor")
	end
end

---@param session AtlasReviewSession
---@param actions AtlasReviewKeymapActions
---@param buf integer
---@param opts AtlasReviewKeymapGroupOptions|nil
---@return AtlasReviewKeymapGroup[]
function M.groups(session, actions, buf, opts)
	opts = opts or {}
	local include_actions = opts.include_actions ~= false
	local content = buf == session.left.buf or buf == session.right.buf
	local new_side = buf == session.right.buf
	local general, review, navigation = {}, {}, {}

	add(general, "ui.refresh", "Refresh review", 20, function()
		comments.reload(session)
		notes.reload(session)
	end)
	add(general, "ui.refresh_view", "Reload pull request diff", 21, opts.reload)
	if include_actions then
		add(general, "ui.open_in_browser", "Open in browser", 30, function()
			actions.open_in_browser(buf)
		end)
		add(review, "pulls.review.toggle_approval", "Approve / unapprove", 8, actions.toggle_approval)
		add(review, "pulls.review.request_changes", "Request changes", 9, actions.request_changes)
		add(review, "pulls.review.submit_review", "Submit review", 10, actions.submit_review)
		if opts.include_task then
			add(review, "pulls.review.diff.toggle_resolved", "Toggle task completion", 11, actions.toggle_task)
		end
	end

	if include_actions and content then
		add(review, "ui.show_details", "Open comment or note", 20, function()
			open_item(session, buf)
		end)
		add(review, "pulls.review.diff.toggle_resolved", "Toggle resolved", 21, function()
			actions.toggle_resolved(buf)
		end)
		add(review, "pulls.review.diff.add_comment", "Add pending inline comment", 30, function()
			actions.add_comment(buf, true)
		end)
		add(review, "pulls.review.diff.submit_comment", "Submit inline comment", 31, function()
			actions.add_comment(buf, false)
		end)
		add(review, "pulls.review.diff.delete", "Delete comment or note at cursor", 32, function()
			if not notes.delete_at_cursor(session, buf) then
				actions.delete_comment(buf)
			end
		end)
		if new_side then
			add(review, "pulls.review.diff.add_note", "Add local note", 33, function()
				notes.add_at_cursor(session, buf)
			end)
		end
		add(review, "ui.toggle_fold", "Toggle review thread", 40, function()
			if not actions.toggle_thread(buf) then
				pcall(vim.cmd.normal, { "za", bang = true })
			end
		end)
		add(review, "ui.toggle_all_folds", "Toggle all review threads", 41, function()
			if not actions.toggle_all_threads() then
				pcall(vim.cmd.normal, { "zA", bang = true })
			end
		end)
		add(navigation, "pulls.review.diff.previous_comment", "Previous review comment", 10, function()
			actions.jump_comment(buf, -1)
		end)
		add(navigation, "pulls.review.diff.next_comment", "Next review comment", 11, function()
			actions.jump_comment(buf, 1)
		end)
		add(navigation, "pulls.review.diff.previous_note", "Previous local note", 20, function()
			notes.jump(session, -1)
		end)
		add(navigation, "pulls.review.diff.next_note", "Next local note", 21, function()
			notes.jump(session, 1)
		end)
	end

	local groups = { { name = "General", index = 90, items = general } }
	if #review > 0 then
		table.insert(groups, { name = "Review", index = 110, items = review })
	end
	if #navigation > 0 then
		table.insert(groups, { name = "Navigation", index = 120, items = navigation })
	end
	return groups
end

---@param action AtlasKeymapActionId
---@return string|string[]|nil
local function keys(action)
	local resolved = resolver.resolve(action)
	if not resolved then
		return nil
	end
	return #resolved == 1 and resolved[1] or resolved
end

---@param active fun(): boolean
---@param callback fun()
---@return fun()
local function guard(active, callback)
	return function()
		if active() then
			callback()
		end
	end
end

---@param session AtlasReviewSession
---@param actions AtlasReviewKeymapActions
---@param buf integer
---@param reload (fun())|nil
local function map_buffer(session, actions, buf, reload)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local help = require("atlas.ui.popups.help")
	local groups = M.groups(session, actions, buf, { reload = reload })
	for _, group in ipairs(groups) do
		local items = {}
		if group.name == "General" then
			table.insert(items, {
				key = "gA",
				desc = "Toggle Atlas help",
				index = 10,
				callback = guard(actions.active, function()
					help.toggle({ buffer = buf })
				end),
				opts = { silent = true, nowait = true },
			})
		end
		for _, definition in ipairs(group.items) do
			local key = keys(definition.action)
			if key then
				table.insert(items, {
					key = key,
					desc = definition.desc,
					index = definition.index,
					callback = guard(actions.active, definition.callback),
					opts = { silent = true, nowait = true },
				})
			end
		end
		help.register(group.name, items, { buffer = buf, index = group.index })
	end
end

---@param session AtlasReviewSession
---@param actions AtlasReviewKeymapActions
---@param opts AtlasReviewKeymapOptions
function M.register(session, actions, opts)
	for _, buf in ipairs(opts.buffers) do
		map_buffer(session, actions, buf, opts.reload)
	end
end

return M
