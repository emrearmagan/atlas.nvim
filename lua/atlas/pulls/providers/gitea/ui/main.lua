local M = {}

local helper = require("atlas.pulls.ui.main.helper")
local icons = require("atlas.ui.shared.icons")
local table_tree = require("atlas.ui.components.table_tree")

---@param pulls PullRequest[]
---@return boolean
local function has_diff_stats(pulls)
	for _, pr in ipairs(pulls) do
		if pr.lines_added ~= nil or pr.lines_removed ~= nil then
			return true
		end
	end
	return false
end

---@param pr PullRequest
---@return string, table[]
local function diff_stats(pr)
	local additions = pr.lines_added or 0
	local deletions = pr.lines_removed or 0
	if additions + deletions == 0 then
		return "", {}
	end

	local added = "+" .. tostring(additions)
	local removed = "-" .. tostring(deletions)
	local text = added .. " " .. removed
	return text,
		{
			{ start_col = 0, end_col = #added, hl_group = "AtlasTextPositive" },
			{ start_col = #added + 1, end_col = #text, hl_group = "AtlasLogError" },
		}
end

---@param columns table[]
---@param include_diff boolean
---@return table[]
local function columns_without_tasks(columns, include_diff)
	local result = {}
	for _, column in ipairs(columns) do
		if column.key ~= "tasks" then
			if include_diff and column.key == "created" then
				table.insert(result, {
					key = "diff",
					name = icons.pulls("changes"),
					max_width = 15,
					can_grow = false,
					header_hl = "AtlasColumnHeader",
				})
			end
			table.insert(result, column)
		end
	end
	return result
end

---@param rows table[]
local function add_diff_stats(rows)
	for _, row in ipairs(rows) do
		local pr = row._item and row._item.pr
		if row.kind == "pr" and pr then
			row.diff, row.diff_hl = diff_stats(pr)
		else
			row.diff = ""
		end
	end
end

---@param row table
---@param column table
---@param context table
---@return table[]|nil
local function cell_hl(row, column, context)
	if column.key == "diff" and row.kind == "pr" then
		return row.diff_hl
	end
	return helper.cell_hl(row, column, context)
end

---@param lines string[]
---@param line_map table<integer, table>
---@param spans table[]
local function add_pr_id_spans(lines, line_map, spans)
	for line_number, item in pairs(line_map) do
		if item.kind == "pr" then
			local start_col, end_col = string.find(lines[line_number], "#%d+")
			if start_col and end_col then
				table.insert(spans, {
					line = line_number - 1,
					start_col = start_col - 1,
					end_col = end_col,
					hl_group = "AtlasTextMuted",
				})
			end
		end
	end
end

---@param pulls PullRequest[]
---@param layout "compact"|"grouped"|"plain"
---@param opts { width: integer }
---@return PullsMainRenderResult
function M.render(pulls, layout, opts)
	local table_data = layout == "compact" and helper.build_compact_table(pulls)
		or helper.build_list_table(pulls, layout)
	local include_diff = has_diff_stats(pulls)
	table_data.columns = columns_without_tasks(table_data.columns, include_diff)
	if include_diff then
		add_diff_stats(table_data.rows)
	end

	local lines, line_map, spans = table_tree.render({
		width = opts.width,
		margin = 1,
		columns = table_data.columns,
		rows = table_data.rows,
		cell_hl = cell_hl,
	})
	add_pr_id_spans(lines, line_map, spans)

	return { lines = lines, spans = spans, line_map = line_map }
end

return M
