local layouts = require("atlas.pulls.ui.layouts")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local M = {}

---@param state RepositoryPulls
---@param width integer
---@return string[], table[], table<integer, PullRequest>
function M.render(state, width)
	local spans, line_map = {}, {}
	local selected = {}
	if state.provider and state.view then
		local _, states = state.provider.resolve_search(state.view)
		for _, value in ipairs(states) do
			selected[value] = true
		end
	end

	local header = " "
	for _, filter in ipairs({ "open", "merged", "declined" }) do
		local label = filter:gsub("^%l", string.upper)
		spans[#spans + 1] = {
			line = 0,
			start_col = #header,
			end_col = #header + #label,
			hl_group = selected[filter] and "AtlasLogInfo" or "AtlasTextMuted",
		}

		header = header .. label .. "  "
	end

	if state.page > 1 or state.next_cursor then
		local page = "Page " .. state.page .. (state.total_pages and ("/" .. state.total_pages) or "")
		header = header .. string.rep(" ", math.max(2, width - vim.api.nvim_strwidth(header) - #page - 1))
		spans[#spans + 1] = { line = 0, start_col = #header, end_col = #header + #page, hl_group = "AtlasTextMuted" }
		header = header .. page
	end

	local query = " " .. icons.get("search") .. " " .. vim.trim((state.query or ""):gsub("%s+", " "))
	query = utils.truncate(query, math.max(1, width - 2))
	spans[#spans + 1] = { line = 1, start_col = 0, end_col = #query, hl_group = "AtlasTextMuted" }
	local lines = { header, query, "" }
	local pulls = state.pulls
	---@cast pulls PullRequest[]
	if #pulls == 0 then
		return lines, spans, line_map
	end

	local table_lines, table_map, table_spans = layouts.render({
		width = width,
		provider_id = state.provider and state.provider.id,
	}, pulls)
	local offset = #lines
	utils.append_block(lines, spans, { lines = table_lines, highlights = table_spans })
	for row, item in pairs(table_map) do
		if item.pr then
			line_map[offset + row] = item.pr
		end
	end

	return lines, spans, line_map
end

return M
