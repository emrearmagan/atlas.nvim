local M = {}

local layout = require("atlas.ui.layout")
local utils = require("atlas.ui.shared.utils")
local panel_state = require("atlas.issues.ui.panel.issue.state")
local header = require("atlas.issues.ui.panel.components.header")
local chips = require("atlas.issues.ui.panel.components.chips")
local panel_tabs = require("atlas.issues.ui.panel.components.tabs")

local ns = vim.api.nvim_create_namespace("atlas.issues.panel")

local PADDING_X = 1

---@param buf integer
---@param spans table[]
local function apply_spans(buf, spans)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, span in ipairs(spans or {}) do
		if span.line ~= nil and span.line_hl_group ~= nil then
			vim.api.nvim_buf_set_extmark(buf, ns, span.line, 0, {
				line_hl_group = span.line_hl_group,
			})
		elseif span.line ~= nil and span.start_col ~= nil and span.end_col ~= nil and span.hl_group ~= nil then
			vim.api.nvim_buf_set_extmark(buf, ns, span.line, span.start_col, {
				end_row = span.line,
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end
	end
end

---@param tab_items IssuesPanelTab[]
---@param get_tab_module fun(key: string): IssuesPanelTabModule|nil
function M.render(tab_items, get_tab_module)
	local buf = layout.buf_id("detail")
	local win = layout.win_id("detail")
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local issue = panel_state.current_issue
	local width = vim.api.nvim_win_get_width(win)

	local lines = {}
	local spans = {}

	if issue == nil then
		lines = { "", "  Nothing selected..." }
		panel_state.line_map = {}
	else
		local state = require("atlas.issues.state")
		local provider = state.provider
		local panel = provider and provider.panel or nil
		local extra_rows = panel and panel.header_rows and panel.header_rows(issue) or nil
		local extra_chips = panel and panel.chips and panel.chips(issue) or nil

		-- Header
		local h_lines, h_spans = header.render(issue, width, extra_rows)
		utils.append_block(lines, spans, { lines = h_lines, highlights = h_spans })

		-- Chips
		local chip_line, chip_spans = chips.render(issue, { extra_chips = extra_chips })
		table.insert(lines, chip_line)
		local chip_base = #lines - 1
		for _, span in ipairs(chip_spans) do
			table.insert(spans, {
				line = chip_base,
				start_col = span.start_col,
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end
		table.insert(lines, "")

		-- Tab bar
		local tab_lines, tab_spans = panel_tabs.render(tab_items, panel_state.current_tab, { width = width, padding_x = PADDING_X })
		utils.append_block(lines, spans, { lines = tab_lines, highlights = tab_spans })
		table.insert(lines, "")

		-- Tab content
		local tab_mod = get_tab_module(panel_state.current_tab)
		local content_offset = #lines
		if tab_mod and type(tab_mod.render) == "function" then
			local tab_lines_c, tab_spans_c, tab_line_map = tab_mod.render(issue, width)
			utils.append_block(lines, spans, { lines = tab_lines_c, highlights = tab_spans_c })

			local adjusted = {}
			for lnum, entry in pairs(tab_line_map or {}) do
				adjusted[content_offset + lnum] = entry
			end
			panel_state.line_map = adjusted
		else
			table.insert(lines, "  Unknown tab: " .. tostring(panel_state.current_tab))
			panel_state.line_map = {}
		end
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	apply_spans(buf, spans)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

return M
