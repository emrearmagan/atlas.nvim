local resolver = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")
local providers = require("atlas.providers")

local M = {}

local next_filter = { all = "unresolved", unresolved = "mine", mine = "all" }

---@param items AtlasHelpKeyItem[]
---@param action AtlasKeymapActionId
---@param description string
---@param index integer
---@param callback fun()
local function add(items, action, description, index, callback)
	local keys = resolver.resolve(action)
	if keys then
		items[#items + 1] = {
			key = keys,
			desc = description,
			index = index,
			callback = callback,
			opts = { nowait = true, silent = true },
		}
	end
end

---@param state AtlasDiffReviewPanel
---@return AtlasDiffReviewPanelRow|nil
local function current(state)
	return state.line_map[vim.api.nvim_win_get_cursor(0)[1]]
end

---@param state AtlasDiffReviewPanel
---@param callbacks { on_select: fun(entry: AtlasDiffReviewPanelRow, focus: boolean), on_action: fun(id: AtlasReviewActionId, target: {comment?: PullsComment, note?: AtlasNote, review_entry?: PullsReviewHistoryEntry, pending?: boolean}) }
function M.setup(state, callbacks)
	local function toggle_fold()
		local entry = current(state)
		if entry and entry.tree_key then
			state.expanded[entry.tree_key] = not state.expanded[entry.tree_key]
			state:render()
		end
	end

	local function toggle_all_folds()
		local expand = false
		for _, value in pairs(state.expanded) do
			if not value then
				expand = true
				break
			end
		end
		for key in pairs(state.expanded) do
			state.expanded[key] = expand
		end
		state:render()
	end

	local function open_selected(focus)
		local entry = current(state)
		if not entry then
			return
		end
		local comment = entry.thread_root or entry.comment
		if entry.note or (comment and (comment.file or comment.inline)) then
			callbacks.on_select(entry, focus)
			return
		end
		toggle_fold()
	end

	---@param id AtlasReviewActionId
	---@param entry AtlasDiffReviewPanelRow
	---@param pending boolean|nil
	local function dispatch(id, entry, pending)
		callbacks.on_action(id, {
			comment = entry.comment,
			note = entry.note,
			review_entry = entry.review_entry,
			pending = pending,
		})
	end

	local function close()
		if not help.is_open() then
			state:close()
		end
	end

	local items = {}
	add(items, "ui.close", "Close review panel", 101, close)
	add(items, "pulls.review.view.toggle_review_panel", "Close review panel", 102, close)
	add(items, "ui.help", "Toggle help", 100, function()
		help.toggle({ buffer = state.buf })
	end)

	add(items, "ui.refresh", "Refresh review", 80, function()
		callbacks.on_action("refresh_review", {})
	end)
	add(items, "ui.select", "Open item in diff", 1, function()
		open_selected(true)
	end)
	add(items, "pulls.review.show_details", "Preview item in diff", 2, function()
		open_selected(false)
	end)
	add(items, "ui.toggle_fold", "Expand / collapse", 10, toggle_fold)
	add(items, "ui.toggle_all_folds", "Expand / collapse all", 11, toggle_all_folds)
	add(items, "pulls.review.panel.cycle_filter", "Cycle filter", 12, function()
		state.filter = next_filter[state.filter]
		state:render()
	end)
	add(items, "ui.open_in_browser", "Open item in browser", 20, function()
		local entry = current(state)
		local target = entry and (entry.review_entry or entry.comment or entry.thread_root)
		local url = target and target.url
		if url and url ~= "" then
			vim.ui.open(url)
		end
	end)

	if state.session.source.kind == "pr" then
		local pr = state.session.source.pr
		---@cast pr PullRequest
		local provider = providers.load(pr.provider, "pulls")
		---@cast provider PullsProvider
		local reviews = provider.capabilities.reviews
		local pending_reviews = reviews and reviews.submit_review ~= nil

		add(items, "ui.open_actions", "Review actions", 0, function()
			callbacks.on_action("open_actions", {})
		end)
		add(items, "pulls.review.approve", "Approve", 60, function()
			callbacks.on_action("approve", {})
		end)
		add(items, "pulls.review.request_changes", "Request changes", 61, function()
			callbacks.on_action("request_changes", {})
		end)
		if pending_reviews then
			add(items, "pulls.review.submit_review", "Submit review", 62, function()
				callbacks.on_action("submit_review", {})
			end)
		end

		local function reply(pending)
			local entry = current(state)
			if entry and entry.note then
				dispatch("note_to_comment", entry, pending)
			elseif entry and entry.comment and not entry.comment.is_task then
				dispatch("add_comment", entry, pending)
			end
		end
		if pending_reviews then
			add(items, "pulls.review.add_comment", "Reply with pending comment", 30, function()
				reply(true)
			end)
		end
		add(items, "pulls.review.submit_comment", "Post reply", 31, function()
			reply(false)
		end)
		add(items, "pulls.review.add_task", "Add task to comment", 35, function()
			local entry = current(state)
			if entry and entry.comment and not entry.comment.is_task then
				dispatch("add_task", entry)
			end
		end)

		local comments = provider.capabilities.comments
		if comments and comments.reactions then
			add(items, "ui.comments.react", "Add reaction", 37, function()
				local entry = current(state)
				if entry and entry.comment and not entry.comment.is_task then
					dispatch("react", entry)
				end
			end)
		end
	end

	add(items, "ui.comments.edit", "Edit review item", 36, function()
		local entry = current(state)
		if not entry then
			return
		end
		if entry.note then
			return dispatch("edit_note", entry)
		end
		if entry.review_entry then
			return dispatch("edit_review", entry)
		end
		if entry.comment then
			dispatch("edit_comment", entry)
		end
	end)
	add(items, "ui.delete", "Delete review item", 41, function()
		local entry = current(state)
		if not entry then
			return
		end
		if entry.note then
			return dispatch("delete_note", entry)
		end
		if entry.comment then
			dispatch("delete_comment", entry)
		end
	end)

	add(items, "pulls.review.toggle_resolved", "Toggle resolved / completed", 40, function()
		local entry = current(state)
		if not entry then
			return
		end
		if entry.note then
			return dispatch("toggle_note_resolved", entry)
		end
		local comment = entry.comment
		if not comment then
			return
		end
		if comment.is_task then
			return dispatch("toggle_task", entry)
		end
		callbacks.on_action("toggle_resolved", { comment = entry.thread_root or comment })
	end)

	help.register("Review", items, { buffer = state.buf, index = 1 })
end

return M
