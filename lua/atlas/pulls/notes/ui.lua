local editor = require("atlas.pulls.notes.ui.editor")
local help = require("atlas.ui.popups.help")
local icons = require("atlas.ui.shared.icons")
local notes = require("atlas.pulls.notes")
local notify = require("atlas.core.notify")
local renderer = require("atlas.pulls.notes.ui.renderer")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")

local M = {}

local BUFFER_NAME = "atlas://notes"
local namespace = vim.api.nvim_create_namespace("atlas.notes")

---@class AtlasNotesUIState
---@field buf integer|nil
---@field win integer|nil
---@field filter { host: string, repository: string, id: string|nil }|nil
---@field documents AtlasNotesUIManagerDocument[]
---@field line_map table<integer, AtlasNotesUIItem>
---@field expanded table<string, boolean>

---@type AtlasNotesUIState
local state = {
	buf = nil,
	win = nil,
	filter = nil,
	documents = {},
	line_map = {},
	expanded = {},
}

---@param action AtlasKeymapActionId
---@return string|nil
local function key_label(action)
	local keymap = resolver.resolve(action)
	return keymap and table.concat(keymap.key, " / ") or nil
end

---@return boolean
local function valid_buffer()
	return state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf)
end

---@return boolean
local function valid_window()
	return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function render()
	if not valid_buffer() then
		return
	end

	local win = valid_window() and state.win or nil
	local filter = state.filter
	local lines, spans, line_map = renderer.render_manager({
		documents = state.documents,
		width = win and vim.api.nvim_win_get_width(win) or vim.o.columns,
		filter_label = filter and filter.repository .. (filter.id and "#" .. filter.id or "") or nil,
		expanded = state.expanded,
		action_keys = {
			edit = key_label("ui.comments.edit"),
			delete = key_label("ui.delete"),
		},
	})
	state.line_map = line_map
	if valid_window() then
		local note_count = 0
		for _, document in ipairs(state.documents) do
			note_count = note_count + #document.notes
		end
		local pull_icon = icons.get("pr")
		local note_icon = icons.get("pin")
		vim.api.nvim_set_option_value(
			"winbar",
			string.format(
				" Atlas Notes %%=%s Pull requests: %d   %s Notes: %d ",
				pull_icon,
				#state.documents,
				note_icon,
				note_count
			),
			{ win = state.win }
		)
	end
	vim.api.nvim_set_option_value("modifiable", true, { buf = state.buf })
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = state.buf })
	utils.apply_spans(state.buf, namespace, spans)
end

local resize_group = vim.api.nvim_create_augroup("AtlasNotesResize", { clear = true })
vim.api.nvim_create_autocmd("WinResized", {
	group = resize_group,
	callback = function()
		if valid_buffer() and valid_window() then
			render()
		end
	end,
})

local function refresh()
	if not valid_buffer() then
		return
	end
	local documents, err = notes.documents()
	if not documents then
		notify.error(err or "Unable to read notes", { vim_notify = true })
		return
	end
	local filter = state.filter
	if filter then
		documents = vim.tbl_filter(function(document)
			local target = document.target
			return target.host == filter.host:lower()
				and target.repository == filter.repository:lower()
				and (filter.id == nil or target.id == filter.id)
		end, documents)
	end
	state.documents = documents
	render()
end

M.refresh = refresh

---@return AtlasNotesUIItem|nil
local function selected_item()
	if not valid_window() or vim.api.nvim_get_current_buf() ~= state.buf then
		return nil
	end
	return state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
end

local function toggle()
	local selected = selected_item()
	local key = selected and selected.tree_key or nil
	if not key then
		return
	end
	state.expanded[key] = not state.expanded[key]
	render()
end

local function show_details()
	local selected = selected_item()
	if selected and selected.note then
		editor.details(selected.note, selected.target, state.buf)
	end
end

local function edit_note()
	local selected = selected_item()
	if not selected or not selected.note then
		notify.warn("Select a note to edit", { vim_notify = true })
		return
	end
	editor.edit(selected.target, selected.note, function(updated, err)
		if not updated then
			notify.error(err or "Unable to update note", { vim_notify = true })
			return
		end
		notify.info("Note updated", { vim_notify = true })
		refresh()
	end)
end

local function delete_notes()
	if not valid_window() or vim.api.nvim_get_current_buf() ~= state.buf then
		return
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
	if #selected == 0 then
		notify.warn("Select a note to delete", { vim_notify = true })
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
				notify.error(err or "Unable to delete note", { vim_notify = true })
				refresh()
				return
			end
		end
		notify.info(#selected == 1 and "Note deleted" or string.format("%d notes deleted", #selected), {
			vim_notify = true,
		})
		refresh()
	end)
end

local function close()
	if valid_window() then
		vim.api.nvim_win_close(state.win, true)
	end
end

---@param items AtlasHelpKeyItem[]
---@param action AtlasKeymapActionId
---@param index integer
---@param callback function
---@param options { mode: string[]|nil, silent: boolean|nil }|nil
local function add_key(items, action, index, callback, options)
	local keymap = resolver.resolve(action)
	if not keymap then
		return
	end
	table.insert(items, {
		key = keymap.key,
		mode = options and options.mode,
		desc = keymap.desc,
		index = index,
		callback = callback,
		opts = { nowait = true, silent = options and options.silent },
	})
end

---@return integer
local function ensure_buffer()
	if valid_buffer() then
		return state.buf
	end
	local buf = vim.api.nvim_create_buf(false, true)
	state.buf = buf
	vim.api.nvim_buf_set_name(buf, BUFFER_NAME)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "atlas-ui.notes", { buf = buf })
	pcall(vim.treesitter.stop, buf)

	local note_keys = {}
	add_key(note_keys, "ui.show_details", 1, show_details)
	add_key(note_keys, "ui.comments.edit", 2, edit_note)
	add_key(note_keys, "ui.delete", 3, delete_notes, { mode = { "n", "x" } })
	add_key(note_keys, "ui.toggle_fold", 4, toggle, { silent = true })
	help.register("Notes", note_keys, { buffer = buf, index = 100 })
	local view_keys = {}
	add_key(view_keys, "ui.refresh_view", 5, refresh)
	add_key(view_keys, "ui.help", 6, function()
		help.toggle({ buffer = buf })
	end)
	add_key(view_keys, "ui.close", 7, close)
	help.register("View", view_keys, { buffer = buf, index = 110 })

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			state.buf = nil
			state.win = nil
			state.line_map = {}
			state.expanded = {}
		end,
	})
	return buf
end

---@param filter { host: string, repository: string, id: string|nil }|nil Only notes of one pull request, or of a whole repository without `id`.
function M.open(filter)
	state.filter = filter

	local buf = ensure_buffer()
	if valid_window() then
		vim.api.nvim_set_current_win(state.win)
		refresh()
		return
	end

	vim.cmd("botright 16split")
	state.win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(state.win, buf)
	vim.api.nvim_set_option_value("number", false, { win = state.win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = state.win })
	vim.api.nvim_set_option_value("list", false, { win = state.win })
	vim.api.nvim_set_option_value("signcolumn", "no", { win = state.win })
	vim.api.nvim_set_option_value("statuscolumn", "", { win = state.win })
	vim.api.nvim_set_option_value("wrap", false, { win = state.win })
	vim.api.nvim_set_option_value("cursorline", true, { win = state.win })
	vim.api.nvim_set_option_value("winfixheight", true, { win = state.win })
	vim.api.nvim_set_option_value("foldenable", false, { win = state.win })
	vim.api.nvim_set_option_value("diff", false, { win = state.win })
	vim.api.nvim_set_option_value("scrollbind", false, { win = state.win })
	vim.api.nvim_set_option_value("cursorbind", false, { win = state.win })
	refresh()
end

function M.clear_all()
	vim.ui.input({ prompt = "Delete all review notes? [y/N]: " }, function(answer)
		answer = vim.trim(tostring(answer or "")):lower()
		if answer ~= "y" and answer ~= "yes" then
			return
		end
		local cleared, err = notes.clear_all()
		if not cleared then
			notify.error(err or "Unable to delete notes", { vim_notify = true })
			return
		end
		state.documents = {}
		state.expanded = {}
		render()
		notify.info("Review notes deleted", { vim_notify = true })
	end)
end

return M
