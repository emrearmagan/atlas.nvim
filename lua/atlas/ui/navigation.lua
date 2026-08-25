local M = {}

local ui_state = require("atlas.ui.state")

local DEBOUNCE_MS = 150
local select_timer = nil
local autocmd_groups = {}

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
	return node.kind == "pr" or node.kind == "issue" or node.kind == "bookmark"
end

function M.current_item()
	local win = require("atlas.ui.dashboard").win()
	if win == nil then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(win)[1]
	return ui_state.line_map[line]
end

local function on_cursor_moved()
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

---@param buf integer
function M.detach(buf)
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
	local win = dashboard.win()
	local buf = dashboard.buf()
	if win == nil then
		return
	end
	if buf == nil then
		return
	end

	local current = vim.api.nvim_win_get_cursor(win)
	local line = current[1]
	local col = current[2]
	local max_line = vim.api.nvim_buf_line_count(buf)
	local step = direction == "up" and -1 or 1
	local line_map = ui_state.line_map

	for lnum = line + step, (direction == "up" and 1 or max_line), step do
		if is_selectable(line_map[lnum]) then
			vim.api.nvim_win_set_cursor(win, { lnum, col })
			on_cursor_moved()
			return
		end
	end

	local fallback = math.max(1, math.min(max_line, line + step))
	vim.api.nvim_win_set_cursor(win, { fallback, col })
	on_cursor_moved()
end

---@param predicate fun(item: table): boolean
---@return boolean
function M.focus_item(predicate)
	local dashboard = require("atlas.ui.dashboard")
	local win = dashboard.win()
	local buf = dashboard.buf()
	if win == nil then
		return false
	end
	if buf == nil then
		return false
	end

	local line_map = ui_state.line_map
	for lnum = 1, vim.api.nvim_buf_line_count(buf) do
		local item = line_map[lnum]
		if is_selectable(item) and predicate(item) then
			vim.api.nvim_win_set_cursor(win, { lnum, 0 })
			on_cursor_moved()
			return true
		end
	end
	return false
end

function M.focus_first_item()
	M.focus_item(function()
		return true
	end)
end

function M.focus_last_item()
	local dashboard = require("atlas.ui.dashboard")
	local win = dashboard.win()
	local buf = dashboard.buf()
	if win == nil then
		return
	end
	if buf == nil then
		return
	end

	local line_map = ui_state.line_map
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
