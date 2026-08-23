local M = {}

local helper = require("atlas.pulls.ui.main.helper")
local icons = require("atlas.ui.shared.icons")
local table_tree = require("atlas.ui.components.table_tree")

---@param layout "compact"|"grouped"|"plain"
---@return table[]
local function columns(layout)
	local result = {
		layout == "compact"
				and { key = "pr_icon", name = "", min_width = 1, can_grow = false, header_hl = "AtlasColumnHeader" }
			or { key = "name", name = "Title", min_width = 42, header_hl = "AtlasColumnHeader" },
	}
	if layout == "compact" then
		table.insert(result, { key = "repo_pr", name = "Title", min_width = 42, header_hl = "AtlasColumnHeader" })
	end
	table.insert(result, {
		key = "conversation",
		name = icons.general("conversation"),
		min_width = 2,
		can_grow = false,
		header_hl = "AtlasColumnHeader",
	})
	table.insert(result, {
		key = "author",
		name = string.format("%s Author", icons.general("user")),
		min_width = 3,
		can_grow = false,
		header_hl = "AtlasColumnHeader",
	})
	table.insert(
		result,
		{ key = "created", name = icons.general("created"), can_grow = false, header_hl = "AtlasColumnHeader" }
	)
	table.insert(
		result,
		{ key = "updated", name = icons.general("updated"), can_grow = false, header_hl = "AtlasColumnHeader" }
	)
	return result
end

---@param lines string[]
---@param line_map table<integer, table>
---@param spans table[]
---@param layout "compact"|"grouped"|"plain"
local function add_pr_reference_spans(lines, line_map, spans, layout)
	for line_number, item in pairs(line_map) do
		if item.kind == "pr" then
			local reference = (layout == "plain" and item.pr.repo_full_name or "") .. "#" .. tostring(item.pr.id)
			local start_col, end_col = string.find(lines[line_number], reference, 1, true)
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
	table_data.columns = columns(layout)

	local lines, line_map, spans = table_tree.render({
		width = opts.width,
		margin = 1,
		columns = table_data.columns,
		rows = table_data.rows,
		cell_hl = helper.cell_hl,
	})
	add_pr_reference_spans(lines, line_map, spans, layout)

	return { lines = lines, spans = spans, line_map = line_map }
end

return M
