local actions = require("atlas.pulls.notes.ui.actions")
local icons = require("atlas.ui.shared.icons")
local keymaps = require("atlas.pulls.notes.ui.keymaps")
local notes = require("atlas.pulls.notes")
local notify = require("atlas.core.notify")
local renderer = require("atlas.pulls.notes.ui.renderer")
local resolver = require("atlas.core.keymaps")

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
---@field expanded table<string, boolean>

---@type AtlasNotesUIState
local state = {
	buf = nil,
	win = nil,
	target_filter = nil,
	documents = {},
	line_map = {},
	expanded = {},
}

---@param action AtlasKeymapActionId
---@return string|nil
local function key_label(action)
	local keys = resolver.resolve(action)
	return keys and table.concat(keys, " / ") or nil
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

	local selected
	if valid_window() then
		local item = state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
		selected = item and item.tree_key or nil
	end
	local lines, spans, line_map = renderer.render_manager({
		documents = state.documents,
		width = valid_window() and vim.api.nvim_win_get_width(state.win) or vim.o.columns,
		target_filter = state.target_filter,
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
		local pull_icon = icons.pulls("pr")
		local note_icon = icons.general("pin")
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
	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(state.buf, namespace, span.line, span.start_col, {
			end_row = span.line,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
	if selected and valid_window() then
		for line = 1, #lines do
			local item = line_map[line]
			if item and item.tree_key == selected then
				vim.api.nvim_win_set_cursor(state.win, { line, 0 })
				break
			end
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
		notify.error(err or "Unable to read notes", { vim_notify = true })
		return
	end
	state.documents = documents
	render()
end

function M.refresh()
	refresh()
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
	vim.api.nvim_set_option_value("filetype", "atlas.notes", { buf = buf })
	vim.api.nvim_set_option_value("syntax", "OFF", { buf = buf })
	pcall(vim.treesitter.stop, buf)
	keymaps.register(buf, actions.new(state, refresh, render))
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

---@param opts AtlasNotesUIOptions|nil
function M.open(opts)
	opts = opts or {}
	require("atlas.ui.shared.highlights").setup()
	local target, err
	if opts.target and opts.target ~= "" then
		target, err = notes.resolve_target(opts.target)
	end
	if err then
		notify.error(err, { vim_notify = true })
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
	vim.api.nvim_set_option_value("foldenable", false, { win = state.win })
	vim.api.nvim_set_option_value("diff", false, { win = state.win })
	vim.api.nvim_set_option_value("scrollbind", false, { win = state.win })
	vim.api.nvim_set_option_value("cursorbind", false, { win = state.win })
	refresh()
end

function M.clear_all()
	vim.ui.input({ prompt = "Delete all local review notes? [y/N]: " }, function(answer)
		answer = vim.trim(tostring(answer or "")):lower()
		if answer ~= "y" and answer ~= "yes" then
			return
		end
		local cleared, err = notes.clear_all()
		if not cleared then
			notify.error(err or "Unable to delete local notes", { vim_notify = true })
			return
		end
		state.documents = {}
		state.expanded = {}
		render()
		notify.info("Local review notes deleted", { vim_notify = true })
	end)
end

return M
