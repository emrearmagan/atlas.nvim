local M = {}

local state = require("atlas.issues.ui.detail.state")

---@return integer|nil win
---@return integer|nil buf
local function detail_win_buf()
	local win = state.win
	local buf = state.buf
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return nil, nil
	end
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return nil, nil
	end
	return win, buf
end

---@param lnum integer
---@return boolean
local function is_selectable(lnum)
	local entry = state.line_map[lnum]
	if entry == nil then
		return false
	end

	local tab_mod
	for _, tab in ipairs(state.tabs) do
		if tab.key == state.current_tab then
			tab_mod = tab.mod
			break
		end
	end
	if tab_mod and tab_mod.is_selectable_line then
		return tab_mod.is_selectable_line(lnum, entry)
	end

	return true
end

---@param direction "up"|"down"
function M.move_cursor(direction)
	local win, buf = detail_win_buf()
	if win == nil or buf == nil then
		return
	end

	local cursor = vim.api.nvim_win_get_cursor(win)
	local line = cursor[1]
	local col = cursor[2]
	local max_line = vim.api.nvim_buf_line_count(buf)
	local step = direction == "up" and -1 or 1
	local bound = direction == "up" and 1 or max_line

	if is_selectable(line) then
		for lnum = line + step, bound, step do
			if is_selectable(lnum) then
				vim.api.nvim_win_set_cursor(win, { lnum, col })
				return
			end
		end
	end

	local next_line = line + step
	if next_line >= 1 and next_line <= max_line then
		vim.api.nvim_win_set_cursor(win, { next_line, col })
	end
end

return M
