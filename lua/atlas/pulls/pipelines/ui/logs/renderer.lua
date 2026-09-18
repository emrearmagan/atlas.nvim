local config = require("atlas.config")
local highlights = require("atlas.pulls.pipelines.highlights")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local ui_utils = require("atlas.ui.utils")

local M = {}

local namespace = vim.api.nvim_create_namespace("atlas.pipelines.logs")

local function text(value)
	return (tostring(value or ""):gsub("[%z\1-\31\127]", " "))
end

---@param styles table[]
---@param spans table[]
---@param row integer
---@param column integer
local function append_highlights(styles, spans, row, column)
	for _, span in ipairs(styles) do
		spans[#spans + 1] = vim.tbl_extend("force", span, {
			line = row,
			start_col = column + span.start_col,
			end_col = column + span.end_col,
		})
	end
end

---@param entries (PullsLogLine|PullsLogGroup)[]
---@param format fun(value: string, is_group: boolean): string, table[]
---@param prepared table<PullsLogLine|PullsLogGroup, { text: string, spans: table[] }>
local function prepare_entries(entries, format, prepared)
	for _, entry in ipairs(entries) do
		local body = entry.name or entry.text
		if entry.text and entry.timestamp and body:sub(1, #entry.timestamp) == entry.timestamp then
			body = body:sub(#entry.timestamp + 2)
		end
		local formatted, spans = format(body, entry.entries ~= nil)
		prepared[entry] = { text = formatted, spans = spans }
		if entry.entries then
			prepare_entries(entry.entries, format, prepared)
		end
	end
end

---@param pane PullsPipelinesLogs
---@param entries (PullsLogLine|PullsLogGroup)[]
---@param lines string[]
---@param spans table[]
---@param prepared table<PullsLogLine|PullsLogGroup, { text: string, spans: table[] }>
---@param depth integer
---@param parent PullsLogGroup|nil
local function append_entries(pane, entries, lines, spans, prepared, depth, parent)
	local indent = string.rep("  ", depth)
	local width = vim.api.nvim_win_get_width(pane.win)
	for _, entry in ipairs(entries) do
		local formatted = prepared[entry]
		pane.entry_rows[entry] = #lines + 1
		if entry.entries then
			---@cast entry PullsLogGroup
			local collapsed = pane.collapsed[entry] == true
			local icon, hl = icons.general(collapsed and "fold_closed" or "fold_open")
			if #entry.entries == 0 then
				icon = " "
			end
			local prefix = indent .. icon .. " "
			spans[#spans + 1] = {
				line = #lines,
				start_col = #indent,
				end_col = #indent + #icon,
				hl_group = hl,
			}
			if entry.state then
				local status_icon, status_hl = icons.pulls_status(entry.state:lower())
				spans[#spans + 1] = {
					line = #lines,
					start_col = #prefix,
					end_col = #prefix + #status_icon,
					hl_group = status_hl,
				}
				prefix = prefix .. status_icon .. " "
			end
			local line = prefix .. formatted.text
			append_highlights(formatted.spans, spans, #lines, #prefix)
			if depth == 0 and entry.duration then
				local elapsed = entry.duration < 60 and string.format("%ds", math.floor(entry.duration))
					or utils.human_duration(entry.duration)
				if entry.duration > 0 and entry.duration < 1 then
					elapsed = string.format("%.1fms", entry.duration * 1000)
				end
				line = line
					.. string.rep(" ", math.max(2, width - vim.fn.strdisplaywidth(line) - #elapsed))
					.. elapsed
				spans[#spans + 1] = {
					line = #lines,
					start_col = #line - #elapsed,
					end_col = #line,
					hl_group = "AtlasTextMuted",
				}
			end
			lines[#lines + 1] = line
			pane.line_map[#lines] = entry
			if not collapsed then
				append_entries(pane, entry.entries, lines, spans, prepared, depth + 1, entry)
			end
		else
			---@cast entry PullsLogLine
			local time = entry.timestamp and entry.timestamp:match("%d%d:%d%d:%d%d")
			local prefix = indent
			if time then
				prefix = prefix .. time .. "  "
				spans[#spans + 1] = {
					line = #lines,
					start_col = #indent,
					end_col = #indent + #time,
					hl_group = "AtlasTextMuted",
				}
			end
			append_highlights(formatted.spans, spans, #lines, #prefix)
			lines[#lines + 1] = prefix .. formatted.text
			pane.line_map[#lines] = parent
		end
	end
end

---@param pane PullsPipelinesLogs
---@param lines string[]
---@param spans table[]
---@param prepared table<PullsLogLine|PullsLogGroup, { text: string, spans: table[] }>
local function append_log(pane, lines, spans, prepared)
	local log = pane.log

	if log == "loading" then
		for _ = 1, math.floor((vim.api.nvim_win_get_height(pane.win) - 1) / 2) do
			lines[#lines + 1] = ""
		end
		local message = pane.spinner and pane.spinner:text("Loading logs...") or "Loading logs..."
		local centered = ui_utils.center_text(message, vim.api.nvim_win_get_width(pane.win))
		utils.push(lines, spans, centered, "AtlasTextMuted")
	elseif type(log) == "string" then
		utils.push(lines, spans, text(log), "AtlasLogError", 2)
	elseif pane.show_raw and pane.source and pane.source.raw ~= "" then
		local raw_lines = vim.split(pane.source.raw:gsub("\r\n", "\n"), "\n", { plain = true })
		if raw_lines[#raw_lines] == "" then
			table.remove(raw_lines)
		end
		for index, entry in ipairs(pane.source.lines) do
			pane.entry_rows[entry] = #lines + index
		end
		vim.list_extend(lines, raw_lines)
	elseif log then
		if #log == 0 then
			utils.push(lines, spans, "No log output.", "AtlasTextMuted", 2)
			return
		end
		append_entries(pane, log, lines, spans, prepared, 0, nil)
	end
end

---@param pane PullsPipelinesLogs
---@return string[], table[]
local function build_content(pane)
	pane.counts = nil
	local selection = pane.selection
	if not selection or not selection.pipeline then
		local lines, spans = {}, {}
		for _ = 1, math.floor((vim.api.nvim_win_get_height(pane.win) - 1) / 2) do
			lines[#lines + 1] = ""
		end
		local prompt = ui_utils.center_text("Select a job to view logs", vim.api.nvim_win_get_width(pane.win))
		utils.push(lines, spans, prompt, "AtlasTextMuted")
		return lines, spans
	end

	local options = config.provider_options(pane.context.provider) or {}
	local format, counts = highlights.new(options.ci and options.ci.highlights)
	local prepared = {}
	if selection.job and type(pane.log) == "table" then
		prepare_entries(pane.log, format, prepared)
		pane.counts = counts
	end

	local lines, spans = {}, {}

	if selection.job and pane.log then
		append_log(pane, lines, spans, prepared)
	end

	return lines, spans
end

---@param buf integer
---@param lines string[]
---@param spans table[]
local function write_buffer(buf, lines, spans)
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(buf, namespace, span.line, span.start_col, {
			end_row = span.hl_eol and span.line + 1 or nil,
			end_col = span.hl_eol and 0 or span.end_col,
			hl_eol = span.hl_eol,
			hl_group = span.hl_group,
			priority = 100,
		})
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---@param pane PullsPipelinesLogs
function M.render(pane)
	if
		not utils.buffer.valid(pane.buf)
		or not utils.window.valid(pane.win)
		or vim.api.nvim_win_get_buf(pane.win) ~= pane.buf
	then
		return
	end

	local view = pane.log == "loading" and { lnum = 1, col = 0, topline = 1, leftcol = 0 }
		or vim.api.nvim_win_call(pane.win, vim.fn.winsaveview)
	vim.api.nvim_set_option_value("winbar", pane.show_raw and " Raw logs " or " Logs ", { win = pane.win })
	pane.line_map = {}
	pane.entry_rows = {}
	local lines, spans = build_content(pane)
	write_buffer(pane.buf, lines, spans)
	vim.api.nvim_win_call(pane.win, function()
		vim.fn.winrestview(view)
	end)
end

return M
