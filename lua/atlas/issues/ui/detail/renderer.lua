local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local header = require("atlas.issues.ui.detail.components.header")
local chips = require("atlas.issues.ui.detail.components.chips")
local tabs = require("atlas.ui.components.tabs")
local state = require("atlas.issues.ui.detail.state")

local ns = vim.api.nvim_create_namespace("atlas.issues.provider_detail")

local PADDING_X = 1

---@param buf integer
---@param spans table[]
local function apply_spans(buf, spans)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, span in ipairs(spans) do
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

---@param tab_items IssuesDetailTabDefinition[]
---@param get_tab_module fun(key: string|nil): IssuesDetailTabModule|nil
function M.render(tab_items, get_tab_module)
	local buf = state.buf
	local win = state.win
	if buf == nil or win == nil then
		return
	end
	if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local issue = state.current_issue
	local details = state.current_details
	local width = vim.api.nvim_win_get_width(win)
	local lines = {}
	local spans = {}

	if issue == nil then
		if state.issue_loading then
			utils.push(lines, spans, spinner.with_text("Loading issue..."), "AtlasTextMuted", PADDING_X)
		else
			lines = { "", "  Nothing selected..." }
		end
		state.line_map = {}
	else
		local provider_detail = state.provider_detail
		local extra_fields = provider_detail
				and provider_detail.header_fields
				and provider_detail.header_fields(issue, details, state.details_loading)
			or {}
		local extra_chips = provider_detail
				and provider_detail.chips
				and provider_detail.chips(issue, details, state.details_loading)
			or {}

		local header_lines, header_spans = header.render(issue, width, extra_fields)
		utils.append_block(lines, spans, { lines = header_lines, highlights = header_spans })

		local chip_lines, chip_spans = chips.render({ width = width, extra_chips = extra_chips })
		if #chip_lines > 0 then
			utils.append_block(lines, spans, { lines = chip_lines, highlights = chip_spans })
			table.insert(lines, "")
		end

		if #tab_items > 1 then
			local tab_lines, tab_spans = tabs.render(tab_items, state.current_tab, width, {
				inactive_hl = "AtlasTextMuted",
				gap = " ",
				padding_x = PADDING_X,
			})
			utils.append_block(lines, spans, { lines = tab_lines, highlights = tab_spans })
			table.insert(lines, "")
		end

		local tab_mod = get_tab_module(state.current_tab)

		local content_offset = #lines
		if tab_mod and tab_mod.render then
			local tab_lines, tab_spans, tab_line_map = tab_mod.render(issue, details, width)
			utils.append_block(lines, spans, { lines = tab_lines, highlights = tab_spans })

			local adjusted = {}
			for lnum, entry in pairs(tab_line_map or {}) do
				adjusted[content_offset + lnum] = entry
			end
			state.line_map = adjusted
			if details == nil and state.current_tab == "overview" then
				if #tab_lines > 0 then
					table.insert(lines, "")
				end
				local text = state.details_loading and spinner.with_text("Loading issue details...")
					or "Issue details unavailable."
				utils.push(lines, spans, text, "AtlasTextMuted", PADDING_X)
			end
		elseif details == nil then
			local text = state.details_loading and spinner.with_text("Loading issue...") or "Issue details unavailable."
			utils.push(lines, spans, text, "AtlasTextMuted", PADDING_X)
			state.line_map = {}
		else
			table.insert(lines, "  Unknown tab: " .. tostring(state.current_tab))
			state.line_map = {}
		end
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	apply_spans(buf, spans)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

return M
