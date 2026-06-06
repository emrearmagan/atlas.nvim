local M = {}

local ui_state = require("atlas.ui.state")

local DEBOUNCE_MS = 150
local select_timer = nil

local function is_selectable(node)
	if type(node) ~= "table" then
		return false
	end
	return node.kind == "pr" or node.kind == "issue" or node.kind == "bookmark"
end

function M.current_item()
	local layout = require("atlas.ui.layout")
	local win = layout.win_id("main")
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(win)[1]
	return (ui_state.line_map or {})[line]
end

local function on_cursor_moved()
	if select_timer then
		select_timer:stop()
	end
	select_timer = vim.defer_fn(function()
		select_timer = nil
		local item = M.current_item()
		if ui_state.on_select then
			ui_state.on_select(item)
		end
	end, DEBOUNCE_MS)
end

function M.move_cursor(direction)
	local layout = require("atlas.ui.layout")
	local win = layout.win_id("main")
	local buf = layout.buf_id("main")
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return
	end
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local current = vim.api.nvim_win_get_cursor(win)
	local line = current[1]
	local col = current[2]
	local max_line = vim.api.nvim_buf_line_count(buf)
	local step = direction == "up" and -1 or 1
	local line_map = ui_state.line_map or {}

	if is_selectable(line_map[line]) then
		for lnum = line + step, (direction == "up" and 1 or max_line), step do
			if is_selectable(line_map[lnum]) then
				vim.api.nvim_win_set_cursor(win, { lnum, col })
				on_cursor_moved()
				return
			end
		end
	end

	local fallback = math.max(1, math.min(max_line, line + step))
	vim.api.nvim_win_set_cursor(win, { fallback, col })
	on_cursor_moved()
end

function M.focus_first_item()
	local layout = require("atlas.ui.layout")
	local win = layout.win_id("main")
	local buf = layout.buf_id("main")
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return
	end
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local line_map = ui_state.line_map or {}
	local max_line = vim.api.nvim_buf_line_count(buf)
	for lnum = 1, max_line do
		if is_selectable(line_map[lnum]) then
			vim.api.nvim_win_set_cursor(win, { lnum, 0 })
			on_cursor_moved()
			return
		end
	end
end

function M.focus_last_item()
	local layout = require("atlas.ui.layout")
	local win = layout.win_id("main")
	local buf = layout.buf_id("main")
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return
	end
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local line_map = ui_state.line_map or {}
	local max_line = vim.api.nvim_buf_line_count(buf)
	for lnum = max_line, 1, -1 do
		if is_selectable(line_map[lnum]) then
			vim.api.nvim_win_set_cursor(win, { lnum, 0 })
			on_cursor_moved()
			return
		end
	end
end

return M
