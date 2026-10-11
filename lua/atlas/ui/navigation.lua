local M = {}

local ui_state = require("atlas.ui.state")

local DEBOUNCE_MS = 150
local select_timer = nil
local autocmd_groups = {}
local selection_ns = vim.api.nvim_create_namespace("atlas.ui.selection")

local function stop_select_timer()
	if select_timer then
		select_timer:stop()
		select_timer:close()
		select_timer = nil
	end
end

local function is_selectable(node)
	if type(node) ~= "table" then
		return false
	end
	return node.kind == "pr" or node.kind == "issue" or node.kind == "bookmark" or node.kind == "starred"
end

local function cells(node)
	return node and node.kind == "board_row" and node.cells or nil
end

local function item_at(node, col)
	local row = cells(node)
	if not row then
		return node
	end
	local selected = row[1]
	for _, cell in ipairs(row) do
		if cell.start_col > col then
			break
		end
		selected = cell
	end
	return selected
end

function M.current_item()
	local win = require("atlas.ui.dashboard").win()
	if win == nil then
		return nil
	end
	local cursor = vim.api.nvim_win_get_cursor(win)
	return item_at(ui_state.line_map[cursor[1]], cursor[2])
end

function M.highlight_current_item()
	local dashboard = require("atlas.ui.dashboard")
	local buf, win = dashboard.buf(), dashboard.win()
	if not buf or not win then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, selection_ns, 0, -1)
	local cursor = vim.api.nvim_win_get_cursor(win)
	local row = ui_state.line_map[cursor[1]]
	vim.api.nvim_set_option_value("cursorline", cells(row) == nil, { win = win })
	local item = item_at(row, cursor[2])
	if item and item.start_col and is_selectable(item) then
		vim.api.nvim_buf_set_extmark(buf, selection_ns, cursor[1] - 1, item.start_col, {
			end_col = item.end_col,
			hl_group = "CursorLine",
			priority = 150,
		})
	end
end

local function on_cursor_moved()
	M.highlight_current_item()
	stop_select_timer()
	select_timer = vim.defer_fn(function()
		select_timer = nil
		if not require("atlas.ui.dashboard").is_active() then
			return
		end
		local item = M.current_item()
		if ui_state.domain then
			require("atlas." .. ui_state.domain .. ".ui.dashboard").select(item)
		end
	end, DEBOUNCE_MS)
end

local function focus(win, lnum, item, select)
	vim.api.nvim_win_set_cursor(win, { lnum, item.start_col or 0 })
	if item.virt_col then
		vim.api.nvim_win_call(win, function()
			local view = vim.fn.winsaveview()
			local width = vim.api.nvim_win_get_width(win)
			local left = item.virt_col
			local right = left + math.min(item.width, width)
			if left < view.leftcol then
				view.leftcol = left
			elseif right > view.leftcol + width then
				view.leftcol = right - width
			end
			vim.fn.winrestview(view)
		end)
	end
	if select ~= false then
		on_cursor_moved()
	end
end

local function current_column(win)
	local cursor = vim.api.nvim_win_get_cursor(win)
	local row = ui_state.line_map[cursor[1]]
	local item = cells(row) and item_at(row, cursor[2])
	return item and item.column
end

---@param buf integer
function M.detach(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, selection_ns, 0, -1)
	end
	local group = autocmd_groups[buf]
	if group then
		autocmd_groups[buf] = nil
		pcall(vim.api.nvim_del_augroup_by_id, group)
	end
	stop_select_timer()
end

---@param buf integer
function M.attach(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	M.detach(buf)
	local group = vim.api.nvim_create_augroup("AtlasUINavigation" .. tostring(buf), { clear = true })
	autocmd_groups[buf] = group

	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = buf,
		callback = on_cursor_moved,
	})
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = group,
		buffer = buf,
		once = true,
		callback = function()
			if autocmd_groups[buf] == group then
				M.detach(buf)
			end
		end,
	})
end

function M.move_cursor(direction)
	local dashboard = require("atlas.ui.dashboard")
	local win, buf = dashboard.win(), dashboard.buf()
	if win == nil or buf == nil then
		return
	end

	local current = vim.api.nvim_win_get_cursor(win)
	local line = current[1]
	local col = current[2]
	local max_line = vim.api.nvim_buf_line_count(buf)
	local step = direction == "up" and -1 or 1
	local line_map = ui_state.line_map
	local column = current_column(win)

	for lnum = line + step, (direction == "up" and 1 or max_line), step do
		local row = cells(line_map[lnum])
		local item = row and row[column or 1] or line_map[lnum]
		if is_selectable(item) then
			if row then
				focus(win, lnum, item)
			else
				vim.api.nvim_win_set_cursor(win, { lnum, col })
				on_cursor_moved()
			end
			return
		end
	end
	if column then
		return
	end

	local fallback = math.max(1, math.min(max_line, line + step))
	vim.api.nvim_win_set_cursor(win, { fallback, col })
	on_cursor_moved()
end

local function find_item(predicate)
	local buf = require("atlas.ui.dashboard").buf()
	if buf == nil then
		return nil
	end

	local line_map = ui_state.line_map
	for lnum = 1, vim.api.nvim_buf_line_count(buf) do
		for _, item in ipairs(cells(line_map[lnum]) or { line_map[lnum] }) do
			if is_selectable(item) and predicate(item) then
				return lnum, item
			end
		end
	end
end

---@param predicate fun(item: table): boolean
---@return boolean
function M.focus_item(predicate)
	local win = require("atlas.ui.dashboard").win()
	if win == nil then
		return false
	end
	local lnum, item = find_item(predicate)
	if lnum then
		focus(win, lnum, item)
		return true
	end
	return false
end

---Retain the selected board card or empty column across a passive render.
---@param previous table|nil
function M.restore_board_selection(previous)
	local win = require("atlas.ui.dashboard").win()
	if win == nil or previous == nil or previous.column == nil then
		return
	end
	local lnum, item
	if previous.key ~= nil then
		lnum, item = find_item(function(candidate)
			return candidate.column ~= nil and candidate.key == previous.key
		end)
	end
	if item == nil then
		lnum = vim.api.nvim_win_get_cursor(win)[1]
		local row = cells(ui_state.line_map[lnum])
		item = row and row[previous.column]
	end
	if item ~= nil then
		focus(win, lnum, item, false)
	end
end

---@param opts? { all_columns?: boolean }
function M.focus_first_item(opts)
	local win = require("atlas.ui.dashboard").win()
	local column = not (opts and opts.all_columns) and win and current_column(win) or nil
	M.focus_item(function(item)
		return column == nil or item.column == column
	end)
end

function M.focus_last_item()
	local dashboard = require("atlas.ui.dashboard")
	local win, buf = dashboard.win(), dashboard.buf()
	if win == nil or buf == nil then
		return
	end

	local line_map = ui_state.line_map
	local max_line = vim.api.nvim_buf_line_count(buf)
	local column = current_column(win)
	for lnum = max_line, 1, -1 do
		local row = cells(line_map[lnum]) or { line_map[lnum] }
		for index = column or #row, column or 1, -1 do
			local item = row[index]
			if is_selectable(item) and (column == nil or item.column == column) then
				focus(win, lnum, item)
				return
			end
		end
	end
end

---@param step integer
function M.move_column(step)
	local win = require("atlas.ui.dashboard").win()
	if not win then
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(win)
	local row = cells(ui_state.line_map[cursor[1]])
	if not row then
		return
	end
	local column = math.max(1, math.min(#row, (current_column(win) or 1) + step))
	focus(win, cursor[1], row[column])
end

return M
