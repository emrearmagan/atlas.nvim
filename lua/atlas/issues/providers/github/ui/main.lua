local M = {}

local icons = require("atlas.ui.shared.icons")
local state = require("atlas.issues.state")

--- GitHub doesnt expose task list progress via the API, so we really have to parse the body to get it. This is pretty sad, but it is what it is.
---@param body string|nil
---@return string
local function task_progress(body)
	local completed = 0
	local total = 0
	for line in (tostring(body or "") .. "\n"):gmatch("(.-)\n") do
		local mark = line:match("^%s*[-*+]%s+%[([xX%s])%]")
		if mark ~= nil then
			total = total + 1
			if mark:lower() == "x" then
				completed = completed + 1
			end
		end
	end
	if total == 0 then
		return "-"
	end
	return string.format("%d/%d", completed, total)
end

---@return table[]
local function columns()
	return {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue", min_width = 42, header_hl = "AtlasColumnHeader" },
		{
			key = "comments",
			name = icons.general("comment"),
			min_width = 2,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{
			key = "tasks",
			name = icons.pulls("tasks"),
			min_width = 3,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{
			key = "assignee",
			name = string.format("%s Assignee", icons.general("user")),
			max_width = 22,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{
			key = "reporter",
			name = string.format("%s Reporter", icons.general("user")),
			max_width = 22,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{ key = "status", name = " Status", can_grow = false, header_hl = "AtlasColumnHeader" },
	}
end

---@param issue Issue
---@param is_child boolean
---@return table
local function issue_to_row(issue, is_child)
	local renderer = require("atlas.issues.providers.github.ui.renderer")
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local row = renderer.format_row(issue, is_child)
	row.comments = tostring(tonumber(raw.comment_count) or 0)
	row.tasks = task_progress(raw.body)
	row._item = { kind = "issue", key = issue.key, _issue = issue }
	row._issue = issue
	row.children = row.children or {}
	return row
end

---@param issue_groups table[]|nil
---@param opts { loading: boolean|nil, spinner: string|nil }|nil
---@return table[]
local function rows(issue_groups, opts)
	local out = {}
	for i, group in ipairs(issue_groups or {}) do
		local root_row = issue_to_row(group.issue, false)
		for _, child in ipairs(group.children or {}) do
			table.insert(root_row.children, issue_to_row(child, true))
		end
		table.insert(out, root_row)

		if i < #(issue_groups or {}) then
			table.insert(out, {
				kind = "separator",
				icon = "",
				name = "",
				comments = "",
				tasks = "",
				assignee = "",
				reporter = "",
				status = "",
				children = {},
			})
		end
	end

	if opts and opts.loading then
		table.insert(out, {
			icon = "",
			name = "",
			comments = "",
			tasks = "",
			assignee = "",
			reporter = "",
			status = "",
		})
		table.insert(out, {
			icon = opts.spinner or "⠋",
			name = "Loading...",
			comments = "",
			tasks = "",
			assignee = "",
			reporter = "",
			status = "",
		})
	end

	return out
end

---@param issue_groups table[]|nil
---@return boolean
local function should_show_indicator(issue_groups)
	for _, group in ipairs(issue_groups or {}) do
		local children = type(group) == "table" and group.children or nil
		if type(children) == "table" and #children > 0 then
			return true
		end
	end
	return false
end

---@param issue_groups table[]|nil
---@param opts { loading: boolean|nil, spinner: string|nil }|nil
---@return { columns: table[], rows: table[] }
function M.build_table(issue_groups, opts)
	return {
		columns = columns(),
		rows = rows(issue_groups, opts),
	}
end

---@param row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
local function cell_hl(row, col, ctx)
	if col.key == "comments" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
	end

	if col.key == "tasks" then
		local task_text = tostring(row.tasks or "")
		local completed, total = task_text:match("^(%d+)/(%d+)$")
		local hl = "AtlasTextMuted"
		if completed and total then
			hl = tonumber(completed) == tonumber(total) and "AtlasTextPositive" or "AtlasTextWarning"
		end
		return { { start_col = 0, end_col = #ctx.padded, hl_group = hl } }
	end

	return require("atlas.issues.providers.github.ui.renderer").cell_hl(row, col, ctx)
end

---@param issue_groups table[]
---@param opts { width: integer }
---@return { lines: string[], spans: table[], line_map: table<integer, table> }
function M.render(issue_groups, opts)
	local table_tree = require("atlas.ui.components.table_tree")
	local table_data = M.build_table(issue_groups, {
		loading = state.is_loading == true,
		spinner = state.reload_spinner_frame,
	})

	local tbl_lines, tbl_map, tbl_spans = table_tree.render({
		width = opts.width,
		margin = 1,
		columns = table_data.columns,
		rows = table_data.rows,
		tree = {
			column_key = "icon",
			children_key = "children",
			default_expanded = true,
			indent = "",
			show_indicator = should_show_indicator(issue_groups),
			leaf_prefix = "",
			is_expanded = function(row)
				local issue = type(row) == "table" and row._issue or nil
				local issue_key = type(issue) == "table" and tostring(issue.key or "") or ""
				if issue_key == "" then
					return true
				end
				return (state.collapsed_issue_keys or {})[issue_key] ~= true
			end,
		},
		cell_hl = cell_hl,
	})

	return { lines = tbl_lines, spans = tbl_spans, line_map = tbl_map }
end

return M
