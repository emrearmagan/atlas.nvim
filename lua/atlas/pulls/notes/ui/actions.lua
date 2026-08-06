local editor = require("atlas.pulls.notes.ui.editor")
local notes = require("atlas.pulls.notes")
local notify = require("atlas.core.notify")

local M = {}

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
---@return { target: AtlasNoteTarget, note: AtlasNote }[]
local function selected_notes(state)
	if not valid_window(state) or vim.api.nvim_get_current_buf() ~= state.buf then
		return {}
	end
	local first = vim.api.nvim_win_get_cursor(state.win)[1]
	local last = first
	local mode = vim.fn.mode()
	if mode == "v" or mode == "V" or mode == "\22" then
		first = vim.fn.line("v")
		if first > last then
			first, last = last, first
		end
		vim.cmd.normal({ args = { vim.keycode("<Esc>") }, bang = true })
	end

	local selected, seen = {}, {}
	for line = first, last do
		local item = state.line_map[line]
		local note = item and item.note or nil
		local key = note and item.tree_key or nil
		if note and not seen[key] then
			seen[key] = true
			table.insert(selected, { target = item.target, note = note })
		end
	end
	return selected
end

---@param state AtlasNotesUIState
---@param refresh fun()
---@param render fun()
---@return AtlasNotesUIActions
function M.new(state, refresh, render)
	local function toggle()
		local selected = selected_item(state)
		local key = selected and selected.tree_key or nil
		if not key then
			return
		end
		state.expanded[key] = not state.expanded[key]
		render()
	end

	local function edit_note()
		local selected = selected_item(state)
		if not selected or not selected.note then
			notify.warn("Select a note to edit")
			return
		end
		editor.edit(selected.target, selected.note, function(updated, err)
			if not updated then
				notify.error(err or "Unable to update note")
				return
			end
			notify.info("Note updated")
			refresh()
		end)
	end

	local function delete_note()
		local selected = selected_notes(state)
		if #selected == 0 then
			notify.warn("Select a note to delete")
			return
		end
		local prompt = #selected == 1 and "Delete note? [y/N]: " or string.format("Delete %d notes? [y/N]: ", #selected)
		vim.ui.input({ prompt = prompt }, function(answer)
			answer = vim.trim(tostring(answer or "")):lower()
			if answer ~= "y" and answer ~= "yes" then
				return
			end
			for _, item in ipairs(selected) do
				local deleted, err = notes.delete(item.target, item.note.id)
				if not deleted then
					notify.error(err or "Unable to delete note")
					refresh()
					return
				end
			end
			notify.info(#selected == 1 and "Note deleted" or string.format("%d notes deleted", #selected))
			refresh()
		end)
	end

	local function show_details()
		local selected = selected_item(state)
		if not selected or not selected.note then
			return
		end
		editor.details(selected.note, selected.target, state.buf)
	end

	local function close()
		if valid_window(state) then
			vim.api.nvim_win_close(state.win, true)
		end
	end

	return {
		toggle = toggle,
		details = show_details,
		edit = edit_note,
		delete = delete_note,
		refresh = refresh,
		close = close,
	}
end

return M
