local providers = require("atlas.issues.ui.components.issue_list.providers")
local table_tree = require("atlas.ui.components.table_tree")
local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")

local M = {}
local STAR_ICON, STAR_ICON_HL = icons.general("star")

---@param display table
---@param issue Issue
---@param is_child boolean|nil
---@param layout AtlasIssuesViewLayout
---@return table
local function issue_to_row(display, issue, is_child, layout)
	local row_data = display.values(issue, is_child == true, layout)

	if issue.is_starred then
		row_data.name = STAR_ICON .. " " .. row_data.name
	end
	row_data._item = { kind = "issue", key = issue.key, _issue = issue }
	row_data._issue = issue
	row_data.children = row_data.children or {}
	return row_data
end

---@param columns table[]
---@return table
local function blank_row(columns)
	local row = {}
	for _, column in ipairs(columns) do
		row[column.key] = ""
	end
	return row
end

---@param display table
---@param row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
local function cell_hl(display, row, col, ctx)
	if row.kind == "meta" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
	end
	if col.key == "icon" and row._fold_icon_hl then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = row._fold_icon_hl } }
	end
	local spans = display.highlights and display.highlights(row, col, ctx) or nil
	if col.key == "name" and row._issue and row._issue.is_starred then
		spans = spans or {}
		table.insert(spans, 1, { start_col = 0, end_col = #STAR_ICON, hl_group = STAR_ICON_HL })
	end
	return spans
end

---@param opts { width: integer, provider_id: string|nil, collapsed?: table<string, boolean>, loading?: boolean, reloading?: table<string, boolean>, spinner?: string }
---@param issue_groups IssuesGroup[]
---@return string[], table<integer, table>, table[]
function M.render_plain(opts, issue_groups)
	local display = providers.get(opts.provider_id, opts)
	local columns = display.columns("plain")
	local collapsed = opts.collapsed or {}
	local rows = {}
	local show_indicator = false
	for i, group in ipairs(issue_groups) do
		local root_row = issue_to_row(display, group.issue, false, "plain")
		for _, child in ipairs(group.children) do
			table.insert(root_row.children, issue_to_row(display, child, true, "plain"))
		end
		if #group.children > 0 then
			if opts.provider_id == "jira" then
				show_indicator = true
			else
				root_row.icon, root_row._fold_icon_hl =
					icons.general(collapsed[group.issue.key] and "fold_closed" or "fold_open")
			end
		end
		table.insert(rows, root_row)
		if i < #issue_groups then
			local separator = blank_row(columns)
			separator.kind = "separator"
			separator.children = {}
			table.insert(rows, separator)
		end
	end
	if opts.loading then
		table.insert(rows, blank_row(columns))
		local loading = blank_row(columns)
		loading.icon = opts.spinner
		loading.name = "Loading..."
		table.insert(rows, loading)
	end

	return table_tree.render({
		width = opts.width,
		margin = 1,
		columns = columns,
		rows = rows,
		hide_columns = { "reporter", "assignee" },
		tree = {
			column_key = "icon",
			children_key = "children",
			default_expanded = true,
			indent = "",
			show_indicator = show_indicator,
			leaf_prefix = "",
			is_expanded = function(row)
				return not row._issue or collapsed[row._issue.key] ~= true
			end,
		},
		cell_hl = function(row, col, ctx)
			return cell_hl(display, row, col, ctx)
		end,
	})
end

---@param issue Issue
---@param provider_id string|nil
---@return string
local function issue_meta_text(issue, provider_id)
	local parts = {}
	local repository
	if provider_id == "github" then
		---@cast issue GitHubIssue
		repository = issue.repo_full_name
	elseif provider_id == "gitlab" then
		---@cast issue GitLabIssue
		repository = issue.project_path
	end
	if repository and repository ~= "" then
		table.insert(parts, repository)
	end
	local type_name = issue.type and tostring(issue.type.name or "") or ""
	if type_name ~= "" then
		table.insert(parts, type_name)
	end
	if provider_id == "jira" then
		---@cast issue JiraIssue
		if issue.priority and issue.priority ~= "" then
			table.insert(parts, issue.priority)
		end
	end
	local due = utils.format_date(issue.duedate)
	if due ~= "" then
		table.insert(parts, string.format("%s %s", icons.general("created"), due))
	end
	if issue.story_points ~= nil then
		table.insert(parts, string.format("%s pts", tostring(issue.story_points)))
	end
	return table.concat(parts, "  ")
end

---@param display table
---@param issues Issue[]
---@param provider_id string|nil
---@return table[], table[]
local function compact_rows(display, issues, provider_id)
	local columns = display.columns("compact")
	local rows = {}
	for _, issue in ipairs(issues) do
		local row = issue_to_row(display, issue, false, "compact")
		row.children = nil
		table.insert(rows, row)

		local meta_text = row._meta
		if meta_text == nil then
			meta_text = issue_meta_text(issue, provider_id)
		end
		if meta_text ~= "" then
			local meta = blank_row(columns)
			meta.kind = "meta"
			meta.name = meta_text
			meta.separator = true
			meta._item = { kind = "issue_meta", key = issue.key, _issue = issue }
			table.insert(rows, meta)
		else
			row.separator = true
		end
	end

	return rows, columns
end

---@param opts { width: integer, provider_id: string|nil, loading?: boolean, reloading?: table<string, boolean>, spinner?: string }
---@param issues Issue[]
---@return string[], table<integer, table>, table[]
function M.render_compact(opts, issues)
	local display = providers.get(opts.provider_id, opts)
	local rows, columns = compact_rows(display, issues, opts.provider_id)
	if opts.loading then
		table.insert(rows, blank_row(columns))
		local loading = blank_row(columns)
		loading.icon = opts.spinner
		loading.name = "Loading..."
		table.insert(rows, loading)
	end

	return table_tree.render({
		width = opts.width,
		margin = 1,
		columns = columns,
		rows = rows,
		hide_columns = { "reporter", "assignee" },
		cell_hl = function(row, col, ctx)
			return cell_hl(display, row, col, ctx)
		end,
	})
end

return M
