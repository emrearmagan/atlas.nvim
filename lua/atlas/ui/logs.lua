local M = {}

local keymaps = require("atlas.core.keymaps")
local logger = require("atlas.core.logger")
local table_view = require("atlas.ui.components.table_tree")
local utils = require("atlas.ui.shared.utils")
local ns = vim.api.nvim_create_namespace("atlas.logs")

local level_hl = {
	DEBUG = "AtlasTextMuted",
	INFO = "AtlasLogInfo",
	WARN = "AtlasLogWarn",
	ERROR = "AtlasLogError",
}

local LOGS_BUFFER_NAME = "atlas://logs"
local REFRESH_INTERVAL_MS = 2000
local logs_buf = nil
local logs_win = nil
local refresh_timer = nil
local line_map = {}
local expanded_rows = {}

---@param line string
---@return table
local function parse_log_line(line)
	local ts, level, rest = string.match(line, "^(%S+)%s+%[([A-Z]+)%]%s+(.*)$")
	if ts == nil then
		return {
			timestamp = "",
			level = "",
			message = line,
			context = "",
		}
	end

	local pipe_at = string.find(rest, " | ", 1, true)
	if pipe_at == nil then
		return {
			timestamp = ts,
			level = level,
			message = rest,
			context = "",
		}
	end

	return {
		timestamp = ts,
		level = level,
		message = string.sub(rest, 1, pipe_at - 1),
		context = string.sub(rest, pipe_at + 3),
	}
end

local function ensure_buf()
	if logs_buf ~= nil and vim.api.nvim_buf_is_valid(logs_buf) then
		return logs_buf
	end

	local existing = vim.fn.bufnr(LOGS_BUFFER_NAME)
	if existing > 0 and vim.api.nvim_buf_is_valid(existing) then
		logs_buf = existing
		return logs_buf
	end

	logs_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(logs_buf, LOGS_BUFFER_NAME)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = logs_buf })
	vim.api.nvim_set_option_value("bufhidden", "hide", { buf = logs_buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = logs_buf })
	vim.api.nvim_set_option_value("filetype", "atlas.logs", { buf = logs_buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = logs_buf })
	vim.api.nvim_set_option_value("syntax", "OFF", { buf = logs_buf })
	pcall(vim.treesitter.stop, logs_buf)

	return logs_buf
end

local function refresh_buffer()
	if logs_buf == nil or not vim.api.nvim_buf_is_valid(logs_buf) then
		return
	end

	local lines = logger.read_lines()
	local rows = {}
	for index, line in ipairs(lines) do
		local raw = tostring(line or "")
		local row = parse_log_line(raw)
		row._log_index = index
		row.display_message = (expanded_rows[index] and "▾ " or "▸ ") .. row.message
		table.insert(rows, row)
	end
	if #rows == 0 then
		rows = {
			{ timestamp = "", level = "", message = "(no logs yet)", display_message = "(no logs yet)", context = "" },
		}
	end

	local width = vim.o.columns
	if logs_win ~= nil and vim.api.nvim_win_is_valid(logs_win) then
		width = vim.api.nvim_win_get_width(logs_win)
	end

	local rendered_lines, rendered_line_map, spans = table_view.render({
		width = width,
		margin = 0,
		fill = false,
		show_header = false,
		columns = {
			{ key = "timestamp", name = "Time", min_width = 19, can_grow = false, header_hl = "Normal" },
			{ key = "level", name = "Level", min_width = 7, can_grow = false, header_hl = "Normal" },
			{ key = "display_message", name = "Message", min_width = 24, header_hl = "Normal" },
		},
		rows = rows,
		cell_hl = function(row, col)
			if col.key == "level" then
				return level_hl[row.level]
			end
			return nil
		end,
	})

	local final_lines = {}
	local final_line_map = {}
	local translated_lines = {}
	for rendered_line, text in ipairs(rendered_lines) do
		translated_lines[rendered_line - 1] = #final_lines
		table.insert(final_lines, text)

		local row = rendered_line_map[rendered_line]
		if row ~= nil then
			final_line_map[#final_lines] = row
		end
		if row ~= nil and expanded_rows[row._log_index] then
			local content = row.context ~= "" and row.context or row.message
			for _, chunk in ipairs(utils.wrap_line(content, math.max(width - 4, 1))) do
				table.insert(final_lines, "  " .. chunk)
				final_line_map[#final_lines] = row
			end
			table.insert(final_lines, "")
			final_line_map[#final_lines] = row
		end
	end

	for _, span in ipairs(spans or {}) do
		span.line = translated_lines[span.line] or span.line
	end
	line_map = final_line_map

	vim.api.nvim_set_option_value("modifiable", true, { buf = logs_buf })
	vim.api.nvim_buf_set_lines(logs_buf, 0, -1, false, final_lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = logs_buf })

	vim.api.nvim_buf_clear_namespace(logs_buf, ns, 0, -1)
	for _, span in ipairs(spans or {}) do
		vim.api.nvim_buf_set_extmark(logs_buf, ns, span.line, span.start_col, {
			end_row = span.line,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
end

local function toggle_details()
	local row = line_map[vim.api.nvim_win_get_cursor(0)[1]]
	if row == nil or row._log_index == nil then
		return
	end

	if expanded_rows[row._log_index] then
		expanded_rows[row._log_index] = nil
	else
		expanded_rows[row._log_index] = true
	end
	refresh_buffer()
	local target_line = nil
	for buffer_line, mapped_row in pairs(line_map) do
		if mapped_row._log_index == row._log_index and (target_line == nil or buffer_line < target_line) then
			target_line = buffer_line
		end
	end
	if target_line ~= nil then
		vim.api.nvim_win_set_cursor(0, { target_line, 0 })
	end
end

local function toggle_all_details()
	local expand = false
	for _, row in pairs(line_map) do
		if row._log_index and not expanded_rows[row._log_index] then
			expand = true
			break
		end
	end

	for _, row in pairs(line_map) do
		if row._log_index then
			expanded_rows[row._log_index] = expand or nil
		end
	end
	refresh_buffer()
end

local function stop_refresh_timer()
	if refresh_timer ~= nil then
		if not refresh_timer:is_closing() then
			refresh_timer:stop()
			refresh_timer:close()
		end
		refresh_timer = nil
	end
end

local function start_refresh_timer()
	stop_refresh_timer()
	refresh_timer = vim.loop.new_timer()
	if refresh_timer == nil then
		return
	end
	refresh_timer:start(
		REFRESH_INTERVAL_MS,
		REFRESH_INTERVAL_MS,
		vim.schedule_wrap(function()
			if logs_win == nil or not vim.api.nvim_win_is_valid(logs_win) then
				stop_refresh_timer()
				return
			end
			refresh_buffer()
		end)
	)
end

local function move_cursor_to_last_line()
	if logs_win == nil or not vim.api.nvim_win_is_valid(logs_win) then
		return
	end

	if logs_buf == nil or not vim.api.nvim_buf_is_valid(logs_buf) then
		return
	end

	local line_count = vim.api.nvim_buf_line_count(logs_buf)
	if line_count < 1 then
		line_count = 1
	end

	vim.api.nvim_win_set_cursor(logs_win, { line_count, 0 })
end

function M.open()
	local buf = ensure_buf()

	if logs_win ~= nil and vim.api.nvim_win_is_valid(logs_win) then
		vim.api.nvim_set_current_win(logs_win)
		refresh_buffer()
		move_cursor_to_last_line()
		start_refresh_timer()
		return
	end

	vim.cmd("botright 12split")
	logs_win = vim.api.nvim_get_current_win()

	vim.api.nvim_win_set_buf(logs_win, buf)
	vim.api.nvim_set_option_value("number", false, { win = logs_win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = logs_win })
	vim.api.nvim_set_option_value("signcolumn", "no", { win = logs_win })
	vim.api.nvim_set_option_value("wrap", false, { win = logs_win })
	vim.api.nvim_set_option_value("cursorline", true, { win = logs_win })
	vim.api.nvim_set_option_value("winfixheight", true, { win = logs_win })
	local fold_keys = keymaps.resolve("ui.toggle_fold") or {}
	local fold_all_keys = keymaps.resolve("ui.toggle_all_folds") or {}
	local refresh_keys = keymaps.resolve("ui.refresh_view") or {}
	local close_keys = keymaps.resolve("ui.close") or {}
	local hints = {}
	if #fold_keys > 0 then
		table.insert(hints, table.concat(fold_keys, " / ") .. " Toggle details")
	end
	if #refresh_keys > 0 then
		table.insert(hints, table.concat(refresh_keys, " / ") .. " Refresh")
	end
	if #close_keys > 0 then
		table.insert(hints, table.concat(close_keys, " / ") .. " Close")
	end
	vim.api.nvim_set_option_value(
		"winbar",
		" Atlas Logs %=%#AtlasTextMuted#" .. table.concat(hints, "   ") .. (#hints > 0 and " " or "") .. "%*",
		{ win = logs_win }
	)
	pcall(vim.api.nvim_win_set_height, logs_win, 12)

	local opts = { buffer = buf, silent = true, nowait = true }
	for _, key in ipairs(close_keys) do
		vim.keymap.set("n", key, M.close, opts)
	end
	for _, key in ipairs(refresh_keys) do
		vim.keymap.set("n", key, refresh_buffer, opts)
	end
	for _, key in ipairs(fold_keys) do
		vim.keymap.set("n", key, toggle_details, opts)
	end
	for _, key in ipairs(fold_all_keys) do
		vim.keymap.set("n", key, toggle_all_details, opts)
	end

	refresh_buffer()
	move_cursor_to_last_line()
	vim.api.nvim_set_current_win(logs_win)
	start_refresh_timer()
end

function M.close()
	stop_refresh_timer()
	if logs_win ~= nil and vim.api.nvim_win_is_valid(logs_win) then
		vim.api.nvim_win_close(logs_win, true)
	end
	logs_win = nil
end

function M.toggle()
	if logs_win ~= nil and vim.api.nvim_win_is_valid(logs_win) then
		M.close()
		return
	end
	M.open()
end

return M
