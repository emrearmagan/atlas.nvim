local M = {}

local anchoring = require("atlas.pulls.diff.shared.comments.anchor")
local statusline = require("atlas.pulls.diff.atlas.statusline")
local note_editor = require("atlas.pulls.notes.ui.editor")
local note_popup = require("atlas.pulls.notes.ui.popup")
local note_renderer = require("atlas.pulls.notes.ui.renderer")
local store = require("atlas.pulls.notes")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local namespace = vim.api.nvim_create_namespace("atlas_diff_notes")
local note_icon, note_icon_hl = icons.general("pin")

---@class AtlasDiffNotesState
---@field target AtlasNoteTarget
---@field items AtlasNote[]

---@param buf integer
local function clear(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	end
end

---@param session AtlasNativeDiffSession
---@param level "loading"|"success"|"error"
---@param message string
local function notify(session, level, message)
	statusline.notify(session, level, message, level == "success" and 1200 or nil)
end

---@param session AtlasNativeDiffSession
---@param index integer
---@return boolean
local function delete_at(session, index)
	local state = session.notes
	if not state then
		return false
	end
	local deleted, err = store.delete(state.target, state.items[index].id)
	if not deleted then
		notify(session, "error", err or "Unable to delete local note")
		return false
	end
	table.remove(state.items, index)
	return true
end

---@param session AtlasNativeDiffSession
local function prune_missing_files(session)
	local state = session.notes
	if not state then
		return
	end
	local files = {}
	for _, file in ipairs(session.files) do
		if file.status ~= "deleted" then
			files[file.path] = true
		end
	end
	for index = #state.items, 1, -1 do
		if not files[state.items[index].file_path] then
			delete_at(session, index)
		end
	end
end

---@param session AtlasNativeDiffSession
local function prune_lines(session)
	local state = session.notes
	local document = session.document
	if not state or not document then
		return
	end
	for index = #state.items, 1, -1 do
		local note = state.items[index]
		if
			note.file_path == document.new.path
			and (document.binary or document.file.status == "deleted" or note.line > #document.new.lines)
		then
			delete_at(session, index)
		end
	end
end

---@param session AtlasNativeDiffSession
---@return AtlasNote[], table<string, boolean>
local function visible_notes(session)
	local state = session.notes
	local document = session.document
	if not state or not document or document.binary or document.file.status == "deleted" then
		return {}, {}
	end
	local items, outdated = {}, {}
	for _, note in ipairs(state.items) do
		if note.file_path == document.new.path and note.line <= #document.new.lines then
			table.insert(items, note)
			outdated[note.id] = store.is_outdated(note, document.new.lines[note.line])
		end
	end
	return items, outdated
end

---@param session AtlasNativeDiffSession
function M.render(session)
	clear(session.left.buf)
	clear(session.right.buf)
	local state = session.notes
	local document = session.document
	if not state or not document or not vim.api.nvim_buf_is_valid(session.right.buf) then
		return
	end
	prune_lines(session)
	if document.binary then
		return
	end

	local grouped = {}
	local items, outdated = visible_notes(session)
	for _, note in ipairs(items) do
		grouped[note.line] = grouped[note.line] or {}
		table.insert(grouped[note.line], note)
	end

	local width = session.right.win
			and vim.api.nvim_win_is_valid(session.right.win)
			and vim.api.nvim_win_get_width(session.right.win)
		or vim.o.columns
	for line, notes in pairs(grouped) do
		local lines, spans = note_renderer.render_cards(notes, width, {
			outdated = outdated,
		})
		local virtual_lines = utils.virtual_lines(lines, spans)
		vim.api.nvim_buf_set_extmark(session.right.buf, namespace, line - 1, 0, {
			virt_lines = virtual_lines,
			virt_lines_leftcol = true,
			sign_text = note_icon,
			sign_hl_group = note_icon_hl,
			priority = 1080,
		})

		if session.layout == "side-by-side" then
			local target, above =
				anchoring.opposite_line(document, "RIGHT", line, vim.api.nvim_buf_line_count(session.left.buf))
			local padding = {}
			for _ = 1, #virtual_lines do
				table.insert(padding, { { "", "Normal" } })
			end
			vim.api.nvim_buf_set_extmark(session.left.buf, namespace, target - 1, 0, {
				virt_lines = padding,
				virt_lines_above = above,
				virt_lines_leftcol = true,
				priority = 1070,
			})
		end
	end
end

---@param state AtlasDiffNotesState
---@param note AtlasNote
local function upsert(state, note)
	for index, existing in ipairs(state.items) do
		if existing.id == note.id then
			state.items[index] = note
			return
		end
	end
	table.insert(state.items, note)
end

---@param state AtlasDiffNotesState
---@param id string
local function remove(state, id)
	for index = #state.items, 1, -1 do
		if state.items[index].id == id then
			table.remove(state.items, index)
		end
	end
end

---@param session AtlasNativeDiffSession
---@param buf integer
---@return AtlasNote[], table<string, boolean>
local function notes_at_cursor(session, buf)
	if not session.notes or not session.document or buf ~= session.right.buf then
		return {}, {}
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local visible, outdated = visible_notes(session)
	local items, selected_outdated = {}, {}
	for _, note in ipairs(visible) do
		if note.line == line then
			table.insert(items, note)
			selected_outdated[note.id] = outdated[note.id]
		end
	end
	return items, selected_outdated
end

---@param session AtlasNativeDiffSession
---@param buf integer
---@return boolean
function M.has_at_cursor(session, buf)
	return #notes_at_cursor(session, buf) > 0
end

---@param session AtlasNativeDiffSession
---@param buf integer
function M.open_at_cursor(session, buf)
	local state = session.notes
	local items, outdated = notes_at_cursor(session, buf)
	if not state or #items == 0 then
		return
	end

	note_popup.open({
		target = state.target,
		notes = items,
		outdated = outdated,
		notify = function(level, message)
			notify(session, level, message)
		end,
		on_change = function(change)
			if change.kind == "delete" then
				remove(state, change.id)
			elseif change.note then
				upsert(state, change.note)
			end
			session.refresh_ui()
		end,
	})
end

---@param session AtlasNativeDiffSession
---@param buf integer
function M.add_at_cursor(session, buf)
	local state = session.notes
	local document = session.document
	if not state or not document or buf ~= session.right.buf then
		statusline.notify(session, "warn", "Local notes can only be added to the new file")
		return
	end
	if document.binary or document.file.status == "deleted" then
		statusline.notify(session, "warn", "Local notes require a text file on the new side")
		return
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local context_start_line = math.max(1, line - 2)
	local context_lines = {}
	for index = context_start_line, math.min(#document.new.lines, line + 2) do
		table.insert(context_lines, document.new.lines[index])
	end
	note_editor.create(state.target, {
		file_path = document.new.path,
		line = line,
		body = "",
		type = "note",
		context = { start_line = context_start_line, lines = context_lines },
	}, function(saved, err)
		if not saved then
			notify(session, "error", err or "Unable to save local note")
			return
		end
		upsert(state, saved)
		session.refresh_ui()
		notify(session, "success", "Local note added")
	end)
end

---@param session AtlasNativeDiffSession
---@param direction 1|-1
function M.jump(session, direction)
	local state = session.notes
	local document = session.document
	local win = session.right.win
	if not state or not document or not win or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local seen, lines = {}, {}
	local visible = visible_notes(session)
	for _, note in ipairs(visible) do
		if not seen[note.line] then
			seen[note.line] = true
			table.insert(lines, note.line)
		end
	end
	table.sort(lines)
	if #lines == 0 then
		statusline.notify(session, "info", "No local notes in this file", 1200)
		return
	end

	vim.api.nvim_set_current_win(win)
	local current = vim.api.nvim_win_get_cursor(win)[1]
	local target = direction > 0 and lines[1] or lines[#lines]
	if direction > 0 then
		for _, line in ipairs(lines) do
			if line > current then
				target = line
				break
			end
		end
	else
		for index = #lines, 1, -1 do
			if lines[index] < current then
				target = lines[index]
				break
			end
		end
	end
	vim.api.nvim_win_set_cursor(win, { target, 0 })
	vim.cmd.normal({ "zvzz", bang = true })
end

---@param session AtlasNativeDiffSession
function M.reload(session)
	local state = session.notes
	if not state then
		return
	end
	local items, err = store.list(state.target)
	if not items then
		statusline.notify(session, "error", err or "Unable to load local notes")
		return
	end
	state.items = items
	prune_missing_files(session)
	session.refresh_ui()
end

---@param session AtlasNativeDiffSession
---@param review AtlasPreparedReviewContext
function M.attach(session, review)
	if session.notes then
		return
	end
	local target, target_error = store.target_for_pull_request(review.pr)
	if not target then
		statusline.notify(session, "error", target_error or "Unable to load local notes")
		return
	end
	---@type AtlasDiffNotesState
	local state = {
		target = target,
		items = {},
	}
	session.notes = state
	M.reload(session)
end

---@param session AtlasNativeDiffSession
function M.detach(session)
	local state = session.notes
	if not state then
		return
	end
	session.notes = nil
	note_popup.close()
	clear(session.left.buf)
	clear(session.right.buf)
end

return M
