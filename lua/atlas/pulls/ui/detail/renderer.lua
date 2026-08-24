local M = {}

local utils = require("atlas.ui.shared.utils")
local state = require("atlas.pulls.ui.detail.state")
local header = require("atlas.pulls.ui.components.header")
local chips = require("atlas.pulls.ui.components.chips")
local detail_tabs = require("atlas.pulls.ui.components.tabs")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")

local ns = vim.api.nvim_create_namespace("atlas.provider_detail")

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
			local line_text = vim.api.nvim_buf_get_lines(buf, span.line, span.line + 1, false)[1] or ""
			local max_col = #line_text
			local sc = math.min(span.start_col, max_col)
			local ec = math.min(span.end_col, max_col)
			if ec > sc then
				vim.api.nvim_buf_set_extmark(buf, ns, span.line, sc, {
					end_row = span.line,
					end_col = ec,
					hl_group = span.hl_group,
				})
			end
		end
	end
end

---@param tab_items PullsDetailTab[]
---@param get_tab_module fun(key: string): PullsDetailTabModule|nil
function M.render(tab_items, get_tab_module)
	local buf = state.buf
	local win = state.win
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local pr = state.current_pr
	local details = state.current_details
	local width = vim.api.nvim_win_get_width(win)
	local winbar_items = {}
	if pr ~= nil then
		if type(state.diffstat) == "table" then
			local additions, deletions = 0, 0
			for _, entry in ipairs(state.diffstat) do
				additions = additions + (tonumber(entry.lines_added) or 0)
				deletions = deletions + (tonumber(entry.lines_removed) or 0)
			end
			if additions + deletions > 0 then
				winbar_items[#winbar_items + 1] = string.format("%%#AtlasTextPositive#+%d%%*", additions)
				winbar_items[#winbar_items + 1] = string.format("%%#AtlasLogError#-%d%%*", deletions)
			end
		end
		if details and details.is_subscribed ~= nil then
			local bell, bell_hl = icons.general(details.is_subscribed and "bell" or "bell_no")
			if details.is_subscribed then
				bell_hl = "AtlasLogInfo"
			end
			winbar_items[#winbar_items + 1] = string.format("%%#%s#%s%%*", bell_hl, bell)
		end
	end
	vim.api.nvim_set_option_value(
		"winbar",
		#winbar_items > 0 and ("%=" .. table.concat(winbar_items, "  ") .. " ") or " ",
		{ win = win }
	)

	local lines = {}
	local spans = {}

	if pr == nil then
		if state.details_loading then
			utils.push(lines, spans, spinner.with_text("Loading pull request..."), "AtlasTextMuted", PADDING_X)
		else
			lines = { "", "  Nothing selected..." }
		end
		state.line_map = {}
	else
		local provider = state.provider
		local provider_detail = provider and provider.capabilities.ui and provider.capabilities.ui.detail
		local extra_fields = provider_detail
				and provider_detail.header_fields
				and provider_detail.header_fields(pr, details, state.details_loading)
			or {}
		local extra_chips = provider_detail
				and provider_detail.chips
				and provider_detail.chips(pr, details, state.details_loading)
			or {}

		-- Header
		local h_lines, h_spans = header.render(details or pr, width, extra_fields)
		utils.append_block(lines, spans, { lines = h_lines, highlights = h_spans })

		-- Chips
		local chip_lines, chip_spans = chips.render(details or pr, {
			width = width,
			extra_chips = extra_chips,
			pipelines = state.pipelines,
			loading = state.details_loading or state.pipelines == "loading",
		})
		if #chip_lines > 0 then
			utils.append_block(lines, spans, { lines = chip_lines, highlights = chip_spans })
			table.insert(lines, "")
		end

		-- Tab bar
		if #tab_items > 1 then
			local tab_lines, tab_spans =
				detail_tabs.render(tab_items, state.current_tab, { width = width, padding_x = PADDING_X })
			utils.append_block(lines, spans, { lines = tab_lines, highlights = tab_spans })
			table.insert(lines, "")
		end

		-- Tab content
		local tab_mod = get_tab_module(state.current_tab)
		local content_offset = #lines
		if tab_mod and details then
			local tab_lines_c, tab_spans_c, tab_line_map = tab_mod.render(details, width)
			utils.append_block(lines, spans, { lines = tab_lines_c, highlights = tab_spans_c })

			-- Offset line_map keys to match buffer line numbers (1-indexed)
			local adjusted = {}
			for lnum, entry in pairs(tab_line_map or {}) do
				adjusted[content_offset + lnum] = entry
			end
			state.line_map = adjusted
		elseif details == nil then
			local text = state.details_loading and spinner.with_text("Loading pull request...")
				or "Pull request details unavailable."
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
