local M = {}

local detail_state = require("atlas.pulls.ui.repo_detail.state")

---@return integer|nil win
---@return integer|nil buf
local function detail_win_buf()
	local win = detail_state.win
	local buf = detail_state.buf
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
	local line_map = detail_state.line_map or {}
	local entry = line_map[lnum]
	if entry == nil then
		return false
	end

	return require("atlas.pulls.ui.repo_detail").is_selectable_line(lnum, entry)
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

	if is_selectable(line) then
		for lnum = line + step, bound, step do
			if is_selectable(lnum) then
				vim.api.nvim_win_set_cursor(win, { lnum, col })
				return
			end
		end
	end

	local next = line + step
	if next >= 1 and next <= max_line then
		vim.api.nvim_win_set_cursor(win, { next, col })
	end
end

function M.focus_first()
	local win, buf = detail_win_buf()
	if win == nil or buf == nil then
		return
	end

	local max_line = vim.api.nvim_buf_line_count(buf)
	for lnum = 1, max_line do
		if is_selectable(lnum) then
			vim.api.nvim_win_set_cursor(win, { lnum, 0 })
			return
		end
	end

	vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

function M.focus_last()
	local win, buf = detail_win_buf()
	if win == nil or buf == nil then
		return
	end

	local max_line = vim.api.nvim_buf_line_count(buf)
	for lnum = max_line, 1, -1 do
		if is_selectable(lnum) then
			vim.api.nvim_win_set_cursor(win, { lnum, 0 })
			return
		end
	end

	vim.api.nvim_win_set_cursor(win, { max_line, 0 })
end

return M
