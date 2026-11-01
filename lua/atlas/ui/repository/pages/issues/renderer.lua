local layouts = require("atlas.issues.ui.layouts")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local M = {}

---@param state RepositoryIssues
---@param width integer
---@return string[], table[], table<integer, Issue>
function M.render(state, width)
	local spans, line_map = {}, {}
	local page = ""
	if state.page > 1 or state.next_cursor then
		page = "Page " .. state.page .. (state.total_pages and ("/" .. state.total_pages) or "")
	end

	local prefix = " " .. icons.get("search") .. " "
	local query = vim.trim((state.query or ""):gsub("%s+", " "))
	query = utils.truncate(query, math.max(1, width - vim.api.nvim_strwidth(prefix) - #page - 3))
	local header = prefix .. query
	if page ~= "" then
		header = header .. string.rep(" ", math.max(2, width - vim.api.nvim_strwidth(header) - #page - 1)) .. page
	end

	spans[#spans + 1] = { line = 0, start_col = 0, end_col = #header, hl_group = "AtlasTextMuted" }
	local lines = { header, "" }
	local issues = state.issues
	---@cast issues Issue[]
	if #issues == 0 then
		return lines, spans, line_map
	end

	local table_lines, table_map, table_spans = layouts.render({
		layout = "compact",
		provider_id = state.provider.id,
		width = width,
	}, issues)
	local offset = #lines
	utils.append_block(lines, spans, { lines = table_lines, highlights = table_spans })
	for row, node in pairs(table_map) do
		if node.kind == "issue" and node.issue then
			line_map[offset + row] = node.issue
		end
	end

	return lines, spans, line_map
end

return M
