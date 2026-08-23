local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local detail_state = require("atlas.issues.ui.detail.state")
local header = require("atlas.issues.ui.detail.components.header")
local chips = require("atlas.issues.ui.detail.components.chips")
local tabs = require("atlas.ui.components.tabs")

local ns = vim.api.nvim_create_namespace("atlas.issues.provider_detail")

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

---@param tab_items IssuesDetailTab[]
---@param get_tab_module fun(key: string): IssuesDetailTabModule|nil
function M.render(tab_items, get_tab_module)
	local buf = detail_state.buf
	local win = detail_state.win
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local issue = detail_state.current_issue
	local details = detail_state.current_details
	local width = vim.api.nvim_win_get_width(win)

	local lines = {}
	local spans = {}

	if issue == nil then
		lines = { "", "  Nothing selected..." }
		detail_state.line_map = {}
	else
		local provider = detail_state.provider
		local provider_detail = provider and provider.capabilities.ui and provider.capabilities.ui.detail
		local extra_rows = provider_detail
				and provider_detail.header_rows
				and provider_detail.header_rows(issue, details, detail_state.header_loading)
			or nil
		local extra_chips = provider_detail
				and provider_detail.chips
				and provider_detail.chips(issue, details, detail_state.header_loading)
			or nil

		-- Header
		local h_lines, h_spans = header.render(details or issue, width, extra_rows)
		utils.append_block(lines, spans, { lines = h_lines, highlights = h_spans })

		-- Chips
		local chip_line, chip_spans = chips.render({ extra_chips = extra_chips })
		if chip_line ~= "" then
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
		end

		-- Tab bar
		if #tab_items > 1 then
			local tab_lines, tab_spans = tabs.render(tab_items, detail_state.current_tab, width, {
				inactive_hl = "AtlasTextMuted",
				gap = " ",
				padding_x = PADDING_X,
			})
			utils.append_block(lines, spans, { lines = tab_lines, highlights = tab_spans })
			table.insert(lines, "")
		end

		-- Tab content
		local tab_mod = get_tab_module(detail_state.current_tab)
		local content_offset = #lines
		if tab_mod and tab_mod.render and details then
			local tab_lines_c, tab_spans_c, tab_line_map = tab_mod.render(details, width)
			utils.append_block(lines, spans, { lines = tab_lines_c, highlights = tab_spans_c })

			local adjusted = {}
			for lnum, entry in pairs(tab_line_map or {}) do
				adjusted[content_offset + lnum] = entry
			end
			detail_state.line_map = adjusted
		elseif details == nil then
			local text = detail_state.header_loading and spinner.with_text("Loading issue...")
				or "Issue details unavailable."
			utils.push(lines, spans, text, "AtlasTextMuted", PADDING_X)
			detail_state.line_map = {}
		else
			table.insert(lines, "  Unknown tab: " .. tostring(detail_state.current_tab))
			detail_state.line_map = {}
		end
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	apply_spans(buf, spans)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

return M
