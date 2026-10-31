local M = {}

local window = require("atlas.pulls.ui.dashboard.window")

local DEBOUNCE_MS = 150
local selected_line = nil

local function is_selectable(node)
	return node ~= nil and (node.kind == "pr" or node.kind == "bookmark" or node.kind == "starred")
end

---@return integer|nil
local function cursor_line()
	local win = window.win()
	return win and vim.api.nvim_win_get_cursor(win)[1]
end

---@return integer[]
local function item_lines()
	local lines = {}
	local buf = window.buf()
	if buf == nil then
		return lines
	end
	for lnum = 1, vim.api.nvim_buf_line_count(buf) do
		if is_selectable(window.line_map[lnum]) then
			lines[#lines + 1] = lnum
		end
	end
	return lines
end

---@param lnum integer
local function select_line(lnum)
	selected_line = lnum
	vim.defer_fn(function()
		if cursor_line() == lnum and window.is_active() then
			require("atlas.pulls.ui.dashboard").select(M.current_item())
		end
	end, DEBOUNCE_MS)
end

---@param lnum integer|nil
---@return boolean
local function focus(lnum)
	local win = window.win()
	if win == nil or lnum == nil then
		return false
	end
	vim.api.nvim_win_set_cursor(win, { lnum, 0 })
	select_line(lnum)
	return true
end

function M.current_item()
	local line = cursor_line()
	return line and window.line_map[line]
end

---@param buf integer
function M.attach(buf)
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = vim.api.nvim_create_augroup("AtlasPullsNavigation" .. buf, { clear = true }),
		buffer = buf,
		callback = function()
			local line = cursor_line()
			if line and line ~= selected_line then
				select_line(line)
			end
		end,
	})
end

---@param direction "up"|"down"
function M.move_cursor(direction)
	local line = cursor_line()
	if line == nil then
		return
	end
	local lines = vim.iter(item_lines())
	local target
	if direction == "down" then
		target = lines:find(function(lnum)
			return lnum > line
		end)
	else
		target = lines:rev():find(function(lnum)
			return lnum < line
		end)
	end
	if target then
		focus(target)
	else
		vim.cmd("normal! " .. (direction == "down" and "j" or "k"))
	end
end

---@param predicate fun(item: table): boolean
---@return boolean
function M.focus_item(predicate)
	return focus(vim.iter(item_lines()):find(function(lnum)
		return predicate(window.line_map[lnum])
	end))
end

function M.focus_first_item()
	focus(item_lines()[1])
end

function M.focus_last_item()
	local lines = item_lines()
	focus(lines[#lines])
end

return M
