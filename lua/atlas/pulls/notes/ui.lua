local actions = require("atlas.pulls.notes.ui.actions")
local keymaps = require("atlas.pulls.notes.ui.keymaps")
local notes = require("atlas.pulls.notes")
local notify = require("atlas.core.notify")
local renderer = require("atlas.pulls.notes.ui.renderer")

local M = {}

local BUFFER_NAME = "atlas://notes"
local namespace = vim.api.nvim_create_namespace("atlas.notes")

---@class AtlasNotesUIOptions
---@field target string|nil

---@class AtlasNotesUIState
---@field buf integer|nil
---@field win integer|nil
---@field target_filter AtlasNoteTarget|nil
---@field documents AtlasNotesUIManagerDocument[]
---@field line_map table<integer, AtlasNotesUIItem>

---@type AtlasNotesUIState
local state = {
	buf = nil,
	win = nil,
	target_filter = nil,
	documents = {},
	line_map = {},
}

---@return boolean
local function valid_buffer()
	return state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf)
end

---@return boolean
local function valid_window()
	return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

---@return AtlasNotesUIItem|nil
local function item_at_cursor()
	if not valid_window() or vim.api.nvim_get_current_buf() ~= state.buf then
		return nil
	end
	return state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
end

local function render()
	if not valid_buffer() then
		return
	end

	local previous = item_at_cursor()
	local previous_note = previous and previous.note and previous.note.id or nil
	local previous_target = previous and previous.target.ref or nil
	local lines, line_map, spans = renderer.render_manager({
		documents = state.documents,
		width = valid_window() and vim.api.nvim_win_get_width(state.win) or vim.o.columns,
		target_filter = state.target_filter,
	})
	state.line_map = line_map
	vim.api.nvim_set_option_value("modifiable", true, { buf = state.buf })
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = state.buf })
	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(state.buf, namespace, span.line, span.start_col, {
			end_row = span.line,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end

	if not valid_window() then
		return
	end
	for line, item in pairs(line_map) do
		if
			(previous_note and item.note and item.note.id == previous_note)
			or (not previous_note and previous_target and item.kind == "target" and item.target.ref == previous_target)
		then
			vim.api.nvim_win_set_cursor(state.win, { line, 0 })
			break
		end
	end
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
	local documents, err
	if state.target_filter then
		local target = state.target_filter
		local items
		items, err = notes.list(target)
		if items then
			documents = #items > 0 and { { target = target, notes = items } } or {}
		end
	else
		documents, err = notes.documents()
	end
	if not documents then
		notify.error(err or "Unable to read notes")
		return
	end
	state.documents = documents
	render()
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
	vim.api.nvim_set_option_value("filetype", "atlas-notes", { buf = buf })
	keymaps.register(buf, actions.new(state, refresh))
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			state.buf = nil
			state.win = nil
			state.line_map = {}
		end,
	})
	return buf
end

---@param opts AtlasNotesUIOptions|nil
function M.open(opts)
	opts = opts or {}
	require("atlas.ui.shared.highlights").setup()
	local target, err
	if opts.target and opts.target ~= "" then
		target, err = notes.resolve_target(opts.target)
	end
	if err then
		notify.error(err)
		return
	end

	state.target_filter = target

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
	vim.api.nvim_set_option_value("signcolumn", "no", { win = state.win })
	vim.api.nvim_set_option_value("statuscolumn", "", { win = state.win })
	vim.api.nvim_set_option_value("wrap", false, { win = state.win })
	vim.api.nvim_set_option_value("cursorline", true, { win = state.win })
	vim.api.nvim_set_option_value("winfixheight", true, { win = state.win })
	vim.api.nvim_set_option_value("diff", false, { win = state.win })
	vim.api.nvim_set_option_value("scrollbind", false, { win = state.win })
	vim.api.nvim_set_option_value("cursorbind", false, { win = state.win })
	refresh()
end

return M
