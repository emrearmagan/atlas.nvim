local M = {}

local layout = require("atlas.ui.layout")
local utils = require("atlas.ui.shared.utils")
local panel_state = require("atlas.pulls.ui.panel.repo.state")
local panel_header = require("atlas.pulls.ui.panel.components.header")
local panel_chips = require("atlas.pulls.ui.panel.components.chips")
local panel_tabs = require("atlas.pulls.ui.panel.components.tabs")

local ns = vim.api.nvim_create_namespace("atlas.repo_panel")
local PADDING_X = 1

---@param buf integer
---@param spans table[]
local function apply_spans(buf, spans)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, span in ipairs(spans or {}) do
		if type(span) == "table" and span.line ~= nil and span.line_hl_group ~= nil then
			vim.api.nvim_buf_set_extmark(buf, ns, span.line, 0, {
				line_hl_group = span.line_hl_group,
			})
		elseif
			type(span) == "table"
			and span.line ~= nil
			and span.start_col ~= nil
			and span.end_col ~= nil
			and span.hl_group ~= nil
		then
			vim.api.nvim_buf_set_extmark(buf, ns, span.line, span.start_col, {
				end_row = span.line,
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end
	end
end

---@param tab_items PullsRepoPanelTab[]
---@param get_tab_module fun(key: string): PullsRepoPanelTabModule|nil
function M.render(tab_items, get_tab_module)
	local buf = layout.buf_id("detail")
	local win = layout.win_id("detail")
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return
	end
	vim.api.nvim_set_option_value("winbar", " ", { win = win })

	local repo = panel_state.current_repo
	local repo_details = type(panel_state.current_repo_details) == "table" and panel_state.current_repo_details or nil
	local width = vim.api.nvim_win_get_width(win)
	local lines = {}
	local spans = {}

	if repo == nil then
		lines = { "", "  Nothing selected..." }
		panel_state.line_map = {}
	else
		local header_lines, header_spans = panel_header.render_repo(repo_details or repo, width, nil)
		utils.append_block(lines, spans, { lines = header_lines, highlights = header_spans })

		local chip_line, chip_spans
		if panel_state.current_repo_details == "loading" and repo_details == nil then
			chip_line, chip_spans = panel_chips.render_loading("Loading repo details...", { padding_x = PADDING_X })
		elseif repo_details ~= nil then
			chip_line, chip_spans = panel_chips.render_repo(repo_details, { padding_x = PADDING_X })
		else
			chip_line, chip_spans = "", {}
		end
		table.insert(lines, chip_line)
		for _, span in ipairs(chip_spans) do
			table.insert(spans, {
				line = #lines - 1,
				start_col = span.start_col,
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end
		table.insert(lines, "")

		if #tab_items > 1 then
			local tab_lines, tab_spans =
				panel_tabs.render(tab_items, panel_state.current_tab, { width = width, padding_x = PADDING_X })
			utils.append_block(lines, spans, { lines = tab_lines, highlights = tab_spans })
			table.insert(lines, "")
		end

		local tab_mod = get_tab_module(panel_state.current_tab)
		local content_offset = #lines
		local detail_error = type(panel_state.current_repo_details) == "string"
			and panel_state.current_repo_details ~= "loading"
		if detail_error then
			utils.push(lines, spans, panel_state.current_repo_details, "AtlasLogError", PADDING_X)
			panel_state.line_map = {}
		elseif tab_mod then
			local tab_lines_c, tab_spans_c, tab_line_map = tab_mod.render(repo, width)
			utils.append_block(lines, spans, { lines = tab_lines_c, highlights = tab_spans_c })
			local adjusted = {}
			for lnum, entry in pairs(tab_line_map or {}) do
				adjusted[content_offset + lnum] = entry
			end
			panel_state.line_map = adjusted
		else
			panel_state.line_map = {}
		end
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	apply_spans(buf, spans)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

return M
