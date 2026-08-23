local M = {}

local core_notify = require("atlas.core.notify")
local note_editor = require("atlas.pulls.notes.ui.editor")
local note_popup = require("atlas.pulls.notes.ui.popup")
local note_renderer = require("atlas.pulls.notes.ui.renderer")
local position = require("atlas.pulls.diff.position")
local store = require("atlas.pulls.notes")
local virtual_lines = require("atlas.ui.components.virtual_lines")

local namespace = vim.api.nvim_create_namespace("atlas_diff_notes")

---@param current AtlasDiffCurrent
function M.clear(current)
	for _, side in ipairs({ current.left, current.right }) do
		if vim.api.nvim_buf_is_valid(side.buf) then
			vim.api.nvim_buf_clear_namespace(side.buf, namespace, 0, -1)
		end
	end
end

---@param session AtlasDiffSession
---@param level "loading"|"success"|"warn"|"error"|"info"
---@param message string
local function notify(session, level, message)
	if session.notify then
		session.notify(level, message, level == "success" and 1200 or nil)
	end
end

---@param note AtlasNote
---@param document AtlasDiffDocument
---@return integer
local function anchor_line(note, document)
	return math.min(note.line, math.max(1, #document.new.lines))
end

---@param session AtlasDiffSession
---@return AtlasNote[], table<string, boolean>
local function visible(session)
	local current = session.current
	if not current or current.document.binary or current.document.status == "deleted" then
		return {}, {}
	end
	local document = current.document
	local notes, outdated = {}, {}
	for _, note in ipairs(session.notes) do
		if
			note.file_path == document.new.path
			or (document.status == "renamed" and note.file_path == document.old.path)
		then
			notes[#notes + 1] = note
			outdated[note.id] = store.is_outdated(note, document.new.lines[note.line])
		end
	end
	return notes, outdated
end

---@param session AtlasDiffSession
---@return AtlasDiffHint[]
function M.hints(session)
	local current = session.current
	if not current then
		return {}
	end
	local items = {}
	local visible_notes = visible(session)
	for _, note in ipairs(visible_notes) do
		items[#items + 1] = {
			buf = current.right.buf,
			line = anchor_line(note, current.document),
			kind = "note",
			text = note.body,
		}
	end
	return items
end

---@param session AtlasDiffSession
function M.render(session)
	local current = session.current
	if not current then
		return
	end
	M.clear(current)
	if not vim.api.nvim_buf_is_valid(current.right.buf) then
		return
	end

	local grouped = {}
	local notes, outdated = visible(session)
	for _, note in ipairs(notes) do
		local line = anchor_line(note, current.document)
		grouped[line] = grouped[line] or {}
		grouped[line][#grouped[line] + 1] = note
	end
	local width = current.right.win
			and vim.api.nvim_win_is_valid(current.right.win)
			and vim.api.nvim_win_get_width(current.right.win)
		or vim.o.columns
	for line, items in pairs(grouped) do
		local lines, spans = note_renderer.render_cards(items, width, { outdated = outdated })
		local rendered_lines = virtual_lines.render(lines, spans)
		vim.api.nvim_buf_set_extmark(current.right.buf, namespace, line - 1, 0, {
			virt_lines = rendered_lines,
			virt_lines_leftcol = true,
			number_hl_group = "CursorLineNr",
			priority = 1080,
		})
		if current.layout == "side-by-side" then
			local target, above =
				position.opposite_line(current.document, "RIGHT", line, vim.api.nvim_buf_line_count(current.left.buf))
			local padding = {}
			for _ = 1, #rendered_lines do
				padding[#padding + 1] = { { "", "Normal" } }
			end
			vim.api.nvim_buf_set_extmark(current.left.buf, namespace, target - 1, 0, {
				virt_lines = padding,
				virt_lines_above = above,
				virt_lines_leftcol = true,
				priority = 1070,
			})
		end
	end
end

---@param note AtlasNote
---@param items AtlasNote[]
local function upsert(items, note)
	for index, current in ipairs(items) do
		if current.id == note.id then
			items[index] = note
			return
		end
	end
	items[#items + 1] = note
end

---@param session AtlasDiffSession
---@param buf integer
---@return AtlasNote[], table<string, boolean>
local function at_cursor(session, buf)
	local current = session.current
	if not current or buf ~= current.right.buf then
		return {}, {}
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local notes, outdated = visible(session)
	local result, selected_outdated = {}, {}
	for _, note in ipairs(notes) do
		if anchor_line(note, current.document) == line then
			result[#result + 1] = note
			selected_outdated[note.id] = outdated[note.id]
		end
	end
	return result, selected_outdated
end

---@param session AtlasDiffSession
---@param buf integer
---@return boolean
function M.has_at_cursor(session, buf)
	return #at_cursor(session, buf) > 0
end

---@param session AtlasDiffSession
---@param buf integer
function M.open_at_cursor(session, buf)
	local notes, outdated = at_cursor(session, buf)
	if #notes == 0 then
		return
	end
	note_popup.open({
		owner = session.id,
		notes = notes,
		outdated = outdated,
		on_edit = function(note)
			M.edit(session, note)
		end,
		on_delete = function(note)
			M.delete(session, note)
		end,
	})
end

---@param session AtlasDiffSession
---@param note AtlasNote
function M.edit(session, note)
	if not session.note_target then
		return
	end
	note_editor.edit(session.note_target, note, function(updated, err)
		if not updated then
			notify(session, "error", err or "Unable to update local note")
			return
		end
		upsert(session.notes, updated)
		session:render()
		notify(session, "success", "Local note updated")
	end)
end

---@param session AtlasDiffSession
---@param note AtlasNote
function M.delete(session, note)
	if not session.note_target then
		return
	end
	vim.ui.input({ prompt = "Delete local note? [y/N]: " }, function(answer)
		answer = vim.trim(tostring(answer or "")):lower()
		if answer ~= "y" and answer ~= "yes" then
			return
		end
		local deleted, err = store.delete(session.note_target, note.id)
		if not deleted then
			notify(session, "error", err or "Unable to delete local note")
			return
		end
		for index = #session.notes, 1, -1 do
			if session.notes[index].id == note.id then
				table.remove(session.notes, index)
			end
		end
		session:render()
		notify(session, "success", "Local note deleted")
	end)
end

---@param session AtlasDiffSession
---@param buf integer
---@return boolean
function M.delete_at_cursor(session, buf)
	local notes = at_cursor(session, buf)
	if #notes == 0 then
		return false
	end
	if #notes > 1 then
		M.open_at_cursor(session, buf)
	else
		M.delete(session, notes[1])
	end
	return true
end

---@param session AtlasDiffSession
---@param buf integer
function M.add_at_cursor(session, buf)
	local current = session.current
	if not session.note_target or not current or buf ~= current.right.buf then
		return
	end
	local document = current.document
	if document.binary or document.status == "deleted" then
		notify(session, "warn", "Local notes require a text file on the new side")
		return
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local first = math.max(1, line - 2)
	local context = {}
	for index = first, math.min(#document.new.lines, line + 2) do
		context[#context + 1] = document.new.lines[index]
	end
	note_editor.create(session.note_target, {
		file_path = document.new.path,
		line = line,
		body = "",
		type = "note",
		context = { start_line = first, lines = context },
	}, function(saved, err)
		if not saved then
			notify(session, "error", err or "Unable to save local note")
			return
		end
		upsert(session.notes, saved)
		session:render()
		notify(session, "success", "Local note added")
	end)
end

---@param session AtlasDiffSession
---@param direction 1|-1
function M.jump(session, direction)
	local current = session.current
	local win = current and current.right.win
	if not current or not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	local seen, lines = {}, {}
	for _, note in ipairs(visible(session)) do
		local line = anchor_line(note, current.document)
		if not seen[line] then
			seen[line] = true
			lines[#lines + 1] = line
		end
	end
	table.sort(lines)
	if #lines == 0 then
		return
	end
	vim.api.nvim_set_current_win(win)
	local cursor = vim.api.nvim_win_get_cursor(win)[1]
	local target = direction > 0 and lines[1] or lines[#lines]
	for _, line in ipairs(lines) do
		if direction > 0 and line > cursor then
			target = line
			break
		elseif direction < 0 and line < cursor then
			target = line
		end
	end
	vim.api.nvim_win_set_cursor(win, { target, 0 })
	vim.cmd.normal({ args = { "zv" }, bang = true })
end

---@param session AtlasDiffSession
function M.reload(session)
	if not session.note_target then
		return
	end
	local notes, err = store.list(session.note_target)
	if not notes then
		notify(session, "error", err or "Unable to load local notes")
		return
	end
	session.notes = notes
	session:render()
end

---@param review AtlasDiffReview|nil
---@return AtlasNoteTarget|nil, AtlasNote[]
function M.load(review)
	if not review then
		return nil, {}
	end
	local target, target_err = store.target_for_pull_request(review.pr)
	if not target then
		core_notify.error(target_err or "Unable to load local notes", { vim_notify = true })
		return nil, {}
	end
	local items, list_err = store.list(target)
	if not items then
		core_notify.error(list_err or "Unable to load local notes", { vim_notify = true })
	end
	return target, items or {}
end

return M
