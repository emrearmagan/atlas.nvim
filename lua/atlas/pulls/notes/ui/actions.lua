local editor = require("atlas.pulls.notes.ui.editor")
local notes = require("atlas.pulls.notes")

local M = {}

---@param message string
---@param level integer|nil
local function notify(message, level)
	vim.notify("[Atlas Notes] " .. message, level or vim.log.levels.INFO)
end

---@param state AtlasNotesUIState
---@return boolean
local function valid_window(state)
	return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

---@param state AtlasNotesUIState
---@return AtlasNotesUIItem|nil
local function selected_item(state)
	if not valid_window(state) or vim.api.nvim_get_current_buf() ~= state.buf then
		return nil
	end
	return state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
end

---@param state AtlasNotesUIState
---@param refresh fun()
---@return AtlasNotesUIActions
function M.new(state, refresh)
	local function edit_note()
		local selected = selected_item(state)
		local note = selected and selected.note or nil
		if not selected or not note then
			notify("Select a note to edit", vim.log.levels.WARN)
			return
		end
		editor.edit(selected.target, note, function(updated, err)
			if not updated then
				notify(err or "Unable to update note", vim.log.levels.ERROR)
				return
			end
			notify("Note updated")
			refresh()
		end)
	end

	local function delete_note()
		local selected = selected_item(state)
		local note = selected and selected.note or nil
		if not selected or not note then
			notify("Select a note to delete", vim.log.levels.WARN)
			return
		end
		vim.ui.input({ prompt = "Delete note? [y/N]: " }, function(answer)
			answer = vim.trim(tostring(answer or "")):lower()
			if answer ~= "y" and answer ~= "yes" then
				return
			end
			local deleted, err = notes.delete(selected.target, note.id)
			if not deleted then
				notify(err or "Unable to delete note", vim.log.levels.ERROR)
				return
			end
			notify("Note deleted")
			refresh()
		end)
	end

	local function show_details()
		local selected = selected_item(state)
		local note = selected and selected.note or nil
		if not selected or not note then
			return
		end
		editor.details(note, selected.target, state.buf)
	end

	local function close()
		if valid_window(state) then
			vim.api.nvim_win_close(state.win, true)
		end
	end

	return {
		details = show_details,
		edit = edit_note,
		delete = delete_note,
		refresh = refresh,
		close = close,
	}
end

return M
