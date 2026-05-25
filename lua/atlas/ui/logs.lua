local M = {}

local logger = require("atlas.core.logger")
local table_view = require("atlas.ui.components.table_tree")
local ns = vim.api.nvim_create_namespace("atlas.logs")

local level_hl = {
	DEBUG = "AtlasTextMuted",
	INFO = "AtlasLogInfo",
	WARN = "AtlasLogWarn",
	ERROR = "AtlasLogError",
}

local LOGS_BUFFER_NAME = "atlas://logs"
local LOGS_RENDER_WIDTH = 10000
local REFRESH_INTERVAL_MS = 2000
local logs_buf = nil
local logs_win = nil
local refresh_timer = nil

---@return integer|nil
function M.win_id()
	if logs_win ~= nil and vim.api.nvim_win_is_valid(logs_win) then
		return logs_win
	end
	return nil
end

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
	vim.api.nvim_set_option_value("filetype", "atlas-logs", { buf = logs_buf })
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
	for _, line in ipairs(lines) do
		table.insert(rows, parse_log_line(tostring(line or "")))
	end
	if #rows == 0 then
		rows = {
			{ timestamp = "", level = "", message = "(no logs yet)", context = "" },
		}
	end

	local width = vim.o.columns
	if logs_win ~= nil and vim.api.nvim_win_is_valid(logs_win) then
		width = vim.api.nvim_win_get_width(logs_win)
	end

	local rendered_lines, _, spans = table_view.render({
		width = math.max(width, LOGS_RENDER_WIDTH),
		margin = 0,
		fill = false,
		columns = {
			{ key = "timestamp", name = "Timestamp", min_width = 19, can_grow = false, header_hl = "Normal" },
			{ key = "level", name = "Level", min_width = 7, can_grow = false, header_hl = "Normal" },
			{ key = "message", name = "Message", min_width = 24, header_hl = "Normal" },
			{ key = "context", name = "Context", min_width = 20, header_hl = "Normal" },
		},
		rows = rows,
		cell_hl = function(row, col)
			if col.key == "level" then
				return level_hl[row.level]
			end
			return nil
		end,
	})

	vim.api.nvim_set_option_value("modifiable", true, { buf = logs_buf })
	vim.api.nvim_buf_set_lines(logs_buf, 0, -1, false, rendered_lines)
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

	local layout = require("atlas.ui.layout")
	local anchor = layout.win_id("footer") or vim.api.nvim_get_current_win()
	vim.api.nvim_win_call(anchor, function()
		vim.cmd("belowright 12split")
		logs_win = vim.api.nvim_get_current_win()
	end)

	vim.api.nvim_win_set_buf(logs_win, buf)
	vim.api.nvim_set_option_value("number", false, { win = logs_win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = logs_win })
	vim.api.nvim_set_option_value("signcolumn", "no", { win = logs_win })
	vim.api.nvim_set_option_value("wrap", false, { win = logs_win })
	vim.api.nvim_set_option_value("cursorline", true, { win = logs_win })
	vim.api.nvim_set_option_value("winfixheight", true, { win = logs_win })
	pcall(vim.api.nvim_win_set_height, logs_win, 12)

	local opts = { buffer = buf, silent = true, nowait = true }
	vim.keymap.set("n", "q", function()
		M.close()
	end, opts)
	vim.keymap.set("n", "R", function()
		refresh_buffer()
	end, opts)

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

function M.refresh()
	refresh_buffer()
end

return M
