local M = {}

local state = require("atlas.pulls.ui.detail.state")

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

---@return PullsDetailTabModule|nil
local function current_tab_mod()
	for _, tab in ipairs(state.tabs) do
		if tab.key == state.current_tab then
			return tab.mod
		end
	end
end

---@param lnum integer
---@return boolean
local function is_selectable(lnum)
	local entry = state.line_map[lnum]
	if entry == nil then
		return false
	end

	local tab_mod = current_tab_mod()
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

	local current = vim.api.nvim_win_get_cursor(win)
	local line = current[1]
	local col = current[2]
	local max_line = vim.api.nvim_buf_line_count(buf)
	local step = direction == "up" and -1 or 1
	local bound = direction == "up" and 1 or max_line

	-- On a selectable line -> try to snap to next selectable
	if is_selectable(line) then
		for lnum = line + step, bound, step do
			if is_selectable(lnum) then
				vim.api.nvim_win_set_cursor(win, { lnum, col })
				return
			end
		end
	end

	-- No selectable found (or wasn't on one) -> move freely one line
	local next = line + step
	if next >= 1 and next <= max_line then
		vim.api.nvim_win_set_cursor(win, { next, col })
	end
end

return M
