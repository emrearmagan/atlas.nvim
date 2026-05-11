local M = {}

local icons = require("atlas.ui.shared.icons")
local state = require("atlas.issues.state")
local utils = require("atlas.ui.shared.utils")

---@return table[]
local function plain_columns()
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

---@return table[]
local function compact_columns()
	return {
		{ key = "icon", name = "", can_grow = false, align = "center", header_hl = "AtlasColumnHeader" },
		{ key = "name", name = "Issue", min_width = 42, header_hl = "AtlasColumnHeader" },
		{
			key = "comments",
			name = icons.general("comment"),
			min_width = 2,
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
		{ key = "created", name = icons.general("created"), can_grow = false, header_hl = "AtlasColumnHeader" },
		{ key = "updated", name = icons.general("updated"), can_grow = false, header_hl = "AtlasColumnHeader" },
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
	row._item = { kind = "issue", key = issue.key, _issue = issue }
	row._issue = issue
	row.children = row.children or {}
	return row
end

---@param issue_groups IssuesGroup[]|nil
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
			assignee = "",
			reporter = "",
			status = "",
		})
		table.insert(out, {
			icon = opts.spinner or "⠋",
			name = "Loading...",
			comments = "",
			assignee = "",
			reporter = "",
			status = "",
		})
	end

	return out
end

---@return table
local function compact_blank_row()
	return { icon = "", name = "", comments = "", assignee = "", reporter = "", created = "", updated = "", status = "" }
end

---@param issue Issue
---@return table
local function compact_issue_to_row(issue)
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local row = issue_to_row(issue, false)
	local number = tonumber(raw.number) or tostring(issue.key or ""):match("#(%d+)$")
	local key_label = number and string.format("#%s", tostring(number)) or tostring(issue.key or "")
	row.name = string.format("%s %s", key_label, issue.summary or "")
	row._compact_key_label = key_label
	row.created = utils.relative_time(raw.created_at)
	row.updated = utils.relative_time(raw.updated_at)
	row.children = nil
	return row
end

---@param issues Issue[]|nil
---@param opts { loading: boolean|nil, spinner: string|nil }|nil
---@return table[]
local function compact_rows(issues, opts)
	local out = {}
	for _, issue in ipairs(issues or {}) do
		table.insert(out, compact_issue_to_row(issue))

		local meta = compact_blank_row()
		meta.kind = "meta"
		meta.name = tostring(issue.key or "")
		meta.separator = true
		meta._item = { kind = "issue_meta", key = issue.key, _issue = issue }
		table.insert(out, meta)
	end

	if opts and opts.loading then
		table.insert(out, compact_blank_row())
		local loading = compact_blank_row()
		loading.icon = opts.spinner or "⠋"
		loading.name = "Loading..."
		table.insert(out, loading)
	end

	return out
end

---@param issue_groups IssuesGroup[]|nil
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

---@param issue_groups IssuesGroup[]|nil
---@param opts { loading: boolean|nil, spinner: string|nil }|nil
---@return { columns: table[], rows: table[] }
function M.build_table(issue_groups, opts)
	return {
		columns = plain_columns(),
		rows = rows(issue_groups, opts),
	}
end

---@param issues Issue[]|nil
---@param opts { loading: boolean|nil, spinner: string|nil }|nil
---@return { columns: table[], rows: table[] }
function M.build_compact_table(issues, opts)
	return {
		columns = compact_columns(),
		rows = compact_rows(issues, opts),
	}
end

---@param row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
local function cell_hl(row, col, ctx)
	if row.kind == "meta" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
	end

	if col.key == "name" and type(row._compact_key_label) == "string" then
		local key_label = row._compact_key_label
		local s, e = ctx.text:find(key_label, 1, true)
		if s and e then
			local spans = { { start_col = s - 1, end_col = e, hl_group = "AtlasGHIssueKey" } }
			local title_start = e + 2
			if title_start <= #ctx.text then
				table.insert(spans, { start_col = title_start - 1, end_col = #ctx.text, hl_group = "Normal" })
			end
			return spans
		end
	end

	if col.key == "comments" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
	end

	if col.key == "created" or col.key == "updated" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
	end

	return require("atlas.issues.providers.github.ui.renderer").cell_hl(row, col, ctx)
end

---@param issue_groups IssuesGroup[]|nil
---@return Issue[]
local function flatten_issue_groups(issue_groups)
	local issues = {}
	for _, group in ipairs(issue_groups or {}) do
		if type(group.issue) == "table" then
			table.insert(issues, group.issue)
		end
		for _, child in ipairs(group.children or {}) do
			table.insert(issues, child)
		end
	end
	return issues
end

---@param issue_groups IssuesGroup[]
---@param layout "plain"|"compact"|nil
---@param opts { width: integer }
---@return IssuesMainRenderResult
function M.render(issue_groups, layout, opts)
	if type(layout) == "table" and opts == nil then
		opts = layout
		layout = "plain"
	end
	opts = opts or {}

	local table_tree = require("atlas.ui.components.table_tree")
	local table_data = nil
	if layout == "compact" then
		local issues = type(state.issues) == "table" and state.issues or flatten_issue_groups(issue_groups)
		table_data = M.build_compact_table(issues, {
			loading = state.is_loading == true,
			spinner = state.reload_spinner_frame,
		})
	else
		table_data = M.build_table(issue_groups, {
			loading = state.is_loading == true,
			spinner = state.reload_spinner_frame,
		})
	end

	local render_opts = {
		width = opts.width,
		margin = 1,
		columns = table_data.columns,
		rows = table_data.rows,
		cell_hl = cell_hl,
	}

	if layout ~= "compact" then
		render_opts.tree = {
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
		}
	end

	local tbl_lines, tbl_map, tbl_spans = table_tree.render(render_opts)

	return { lines = tbl_lines, spans = tbl_spans, line_map = tbl_map }
end

return M
