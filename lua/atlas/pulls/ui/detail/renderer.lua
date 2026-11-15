local M = {}

local utils = require("atlas.ui.shared.utils")
local state = require("atlas.pulls.ui.detail.state")
local header = require("atlas.pulls.ui.components.header")
local chips = require("atlas.pulls.ui.components.chips")
local tabs = require("atlas.ui.components.tabs")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")

local ns = vim.api.nvim_create_namespace("atlas.provider_detail")

local PADDING_X = 1

function M.render()
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
		local diffstat = state.diffstat
		if type(diffstat) == "table" then
			local additions, deletions = 0, 0
			for _, entry in ipairs(diffstat) do
				additions = additions + (tonumber(entry.lines_added) or 0)
				deletions = deletions + (tonumber(entry.lines_removed) or 0)
			end
			if additions + deletions > 0 then
				winbar_items[#winbar_items + 1] = string.format("%%#AtlasTextPositive#+%d%%*", additions)
				winbar_items[#winbar_items + 1] = string.format("%%#AtlasLogError#-%d%%*", deletions)
			end
		end
		if details and details.is_subscribed ~= nil then
			local bell, bell_hl = icons.get(details.is_subscribed and "bell" or "bell_no")
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
		if state.pr_loading then
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

		local link_count = #(state.links and state.links.items or {})
		if link_count > 0 then
			table.insert(extra_chips, {
				label = icons.get("link") .. " " .. link_count .. " link" .. (link_count == 1 and "" or "s"),
				hl = "AtlasRelatedChip",
			})
		end

		-- Header
		local h_lines, h_spans = header.render(pr, width, extra_fields)
		utils.append_block(lines, spans, { lines = h_lines, highlights = h_spans })

		-- Chips
		local chip_lines, chip_spans = chips.render(pr, {
			width = width,
			extra_chips = extra_chips,
			checks = state.merge_checks,
		})
		if #chip_lines > 0 then
			utils.append_block(lines, spans, { lines = chip_lines, highlights = chip_spans })
			table.insert(lines, "")
		end

		-- Tab bar
		if #state.tabs > 1 then
			local tab_lines, tab_spans = tabs.render(state.tabs, state.current_tab, width, {
				inactive_hl = "AtlasTextMuted",
				gap = " ",
				padding_x = PADDING_X,
			})
			utils.append_block(lines, spans, { lines = tab_lines, highlights = tab_spans })
			table.insert(lines, "")
		end

		-- Tab content
		local tab_mod = state.tab_module(state.current_tab)
		local content_offset = #lines
		if tab_mod then
			local tab_lines_c, tab_spans_c, tab_line_map = tab_mod.render(pr, details, width)
			utils.append_block(lines, spans, { lines = tab_lines_c, highlights = tab_spans_c })

			-- Offset line_map keys to match buffer line numbers (1-indexed)
			local adjusted = {}
			for lnum, entry in pairs(tab_line_map or {}) do
				adjusted[content_offset + lnum] = entry
			end
			state.line_map = adjusted
		else
			table.insert(lines, "  Unknown tab: " .. tostring(state.current_tab))
			state.line_map = {}
		end
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	utils.apply_spans(buf, ns, spans)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

return M
