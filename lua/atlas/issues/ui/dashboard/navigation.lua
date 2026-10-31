local M = {}

local state = require("atlas.issues.state")
local window = require("atlas.issues.ui.dashboard.window")

local DEBOUNCE_MS = 150
local highlight_ns = vim.api.nvim_create_namespace("atlas.issues.board")
local selected_line, selected_column = nil, nil

local function is_selectable(node)
	return node ~= nil and (node.kind == "issue" or node.kind == "bookmark" or node.kind == "starred")
end

local function cell_at(row, col)
	local current = row.cells[1]
	for _, cell in ipairs(row.cells) do
		if cell.start_col <= col then
			current = cell
		end
	end
	return current
end

---@return { lnum: integer, col: integer, column?: integer, item: table }[]
local function positions()
	local list = {}
	local buf = window.buf()
	if buf == nil then
		return list
	end
	for lnum = 1, vim.api.nvim_buf_line_count(buf) do
		local node = window.line_map[lnum]
		if node and node.kind == "board_row" then
			for _, cell in ipairs(node.cells) do
				if cell.issue then
					list[#list + 1] = { lnum = lnum, col = cell.start_col, column = cell.column, item = cell }
				end
			end
		elseif is_selectable(node) then
			list[#list + 1] = { lnum = lnum, col = 0, item = node }
		end
	end
	return list
end

---@return { lnum: integer, column?: integer, item?: table }|nil
local function cursor()
	local win = window.win()
	if win == nil then
		return nil
	end
	local position = vim.api.nvim_win_get_cursor(win)
	local node = window.line_map[position[1]]
	if node and node.kind == "board_row" then
		local cell = cell_at(node, position[2])
		return { lnum = position[1], column = cell.column, item = cell }
	end
	return { lnum = position[1], item = node }
end

local function select_current()
	local current = cursor()
	if current == nil then
		return
	end
	selected_line, selected_column = current.lnum, current.column
	vim.defer_fn(function()
		local now = cursor()
		if now and now.lnum == current.lnum and now.column == current.column and window.is_active() then
			require("atlas.issues.ui.dashboard").select(now.item)
		end
	end, DEBOUNCE_MS)
end

local function board_cell(lnum, column)
	local row = window.line_map[lnum]
	if row == nil or row.kind ~= "board_row" then
		return nil
	end

	return vim.iter(row.cells):find(function(cell)
		return cell.column == column
	end)
end

---@param column integer
local function reveal(row, column)
	local first, last = row.cells[1].column, row.cells[#row.cells].column
	if column < first then
		state.board_column = column
	elseif column > last then
		state.board_column = column - (last - first)
	else
		return
	end

	window.render()
end

---@param position { lnum: integer, col: integer }|nil
---@return boolean
local function focus(position)
	local win = window.win()
	if win == nil or position == nil then
		return false
	end
	vim.api.nvim_win_set_cursor(win, { position.lnum, position.col })
	M.highlight_current_item()
	select_current()
	return true
end

function M.current_item()
	local current = cursor()
	return current and current.item
end

function M.reset()
	state.board_column = 1
	selected_line, selected_column = nil, nil
end

function M.keep_board_selection()
	local win = window.win()
	if win == nil or selected_column == nil then
		return
	end

	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	local row = window.line_map[lnum]
	if row == nil or row.kind ~= "board_row" or selected_column > row.column_count then
		return
	end

	reveal(row, selected_column)
	local cell = board_cell(lnum, selected_column)
	if cell then
		vim.api.nvim_win_set_cursor(win, { lnum, cell.start_col })
		M.highlight_current_item()
	end
end

function M.highlight_current_item()
	local buf, win, current = window.buf(), window.win(), cursor()
	if buf == nil or win == nil or current == nil then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, highlight_ns, 0, -1)
	vim.wo[win].cursorline = current.column == nil
	if current.column and current.item.issue then
		vim.api.nvim_buf_set_extmark(buf, highlight_ns, current.lnum - 1, current.item.start_col, {
			end_col = current.item.end_col,
			hl_group = "CursorLine",
			priority = 150,
		})
	end
end

---@param buf integer
function M.attach(buf)
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = vim.api.nvim_create_augroup("AtlasIssuesNavigation" .. buf, { clear = true }),
		buffer = buf,
		callback = function()
			M.highlight_current_item()
			local current = cursor()
			if current and (current.lnum ~= selected_line or current.column ~= selected_column) then
				select_current()
			end
		end,
	})
end

---@param direction "up"|"down"
function M.move_cursor(direction)
	local current = cursor()
	if current == nil then
		return
	end
	local function reachable(position)
		return current.column == nil or position.column == nil or position.column == current.column
	end
	local candidates = vim.iter(positions()):filter(reachable)
	local target
	if direction == "down" then
		target = candidates:find(function(position)
			return position.lnum > current.lnum
		end)
	else
		target = candidates:rev():find(function(position)
			return position.lnum < current.lnum
		end)
	end
	if target then
		focus(target)
	else
		vim.cmd("normal! " .. (direction == "down" and "j" or "k"))
	end
end

---@param step integer
function M.move_column(step)
	local current = cursor()
	if current == nil or current.column == nil then
		vim.cmd("normal! " .. math.abs(step) .. (step < 0 and "h" or "l"))
		return
	end
	local row = window.line_map[current.lnum]
	local target = math.max(1, math.min(row.column_count, current.column + step))
	selected_column = target
	reveal(row, target)
	local column = vim.tbl_filter(function(position)
		return position.column == target
	end, positions())
	local beside = vim.iter(column):rev():find(function(position)
		return position.lnum <= current.lnum
	end)
	focus(beside or column[1])
end

---@param predicate fun(item: table): boolean
---@return boolean
function M.focus_item(predicate)
	return focus(vim.iter(positions()):find(function(position)
		return predicate(position.item)
	end))
end

function M.focus_first_item()
	focus(positions()[1])
end

function M.focus_last_item()
	local list = positions()
	focus(list[#list])
end

return M
