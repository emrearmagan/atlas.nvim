local presentation = require("atlas.issues.ui.presentation")
local table_tree = require("atlas.ui.components.table_tree")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local M = {}

local STAR_ICON, STAR_HIGHLIGHT = icons.general("star")

---@param issue Issue
---@param opts { reloading?: table<string, boolean>, spinner?: string }
---@return string
local function status_value(issue, opts)
	local issue_key = issue.key

	if opts.reloading and opts.reloading[issue_key] then
		return string.format(" %s ", opts.spinner)
	end

	return string.format(" %s ", issue.status or "")
end

---@param user AtlasUser|nil
---@param fallback string
---@return string
local function person_value(user, fallback)
	local name = user and user.name or fallback

	return string.format("%s %s", icons.general("user"), utils.shorten_name(name, 20))
end

local function state_icon(status_id)
	if status_id == "closed" then
		return icons.pulls_status("successful"), "AtlasIssueClosed"
	end

	return icons.issues("issue"), "AtlasIssueOpen"
end

local function state_chip_highlight(status_id)
	return status_id == "closed" and "AtlasIssueClosedChip" or "AtlasIssueOpenChip"
end

---@param display table
---@param issue Issue
---@param is_child boolean|nil
---@return table
local function issue_to_row(display, issue, is_child)
	local row_data = display.values(issue, is_child == true)

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
---@param column table
---@param context { text: string, padded: string, width: integer }
---@return table[]|nil
local function cell_highlights(display, row, column, context)
	if column.key == "icon" and row._fold_icon_hl then
		return { { start_col = 0, end_col = #context.padded, hl_group = row._fold_icon_hl } }
	end

	local spans = display.highlights and display.highlights(row, column, context) or nil

	if column.key == "name" and row._issue and row._issue.is_starred then
		spans = spans or {}
		table.insert(spans, 1, { start_col = 0, end_col = #STAR_ICON, hl_group = STAR_HIGHLIGHT })
	end

	return spans
end

---@param opts table
---@param issues Issue[]
---@return string[], table<integer, table>, table[]
local function render(opts, issues, display, tree_indicator)
	local issue_groups = opts.groups

	if issue_groups == nil then
		issue_groups = {}

		for _, issue in ipairs(issues) do
			issue_groups[#issue_groups + 1] = { issue = issue, children = {} }
		end
	end

	local columns = display.columns
	local collapsed = opts.collapsed or {}
	local rows = {}
	local show_indicator = false

	for i, group in ipairs(issue_groups) do
		local root_row = issue_to_row(display, group.issue, false)

		for _, child in ipairs(group.children) do
			table.insert(root_row.children, issue_to_row(display, child, true))
		end

		if #group.children > 0 then
			if tree_indicator then
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

	local function is_expanded(row)
		return not row._issue or collapsed[row._issue.key] ~= true
	end

	local function highlight_cell(row, column, context)
		return cell_highlights(display, row, column, context)
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
			is_expanded = is_expanded,
		},
		cell_hl = highlight_cell,
	})
end

function M.github(opts, issues)
	local columns = {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue", min_width = 42 },

		{
			key = "comments",
			name = icons.general("comment"),
			min_width = 2,
			can_grow = false,
		},

		{
			key = "assignee",
			name = string.format("%s Assignee", icons.general("user")),
			min_width = 10,
			max_width = 22,
			can_grow = false,
		},

		{
			key = "reporter",
			name = string.format("%s Reporter", icons.general("user")),
			min_width = 10,
			max_width = 22,
			can_grow = false,
		},

		{ key = "status", name = " Status", can_grow = false },
	}

	---@param issue GitHubIssue
	local function key_label(issue)
		return string.format("#%d", issue.number)
	end

	local function values(issue, is_child)
		---@cast issue GitHubIssue
		local label = key_label(issue)
		local is_pinned = issue.is_pinned == true
		local row_icon = is_pinned and icons.general("pin") or state_icon(issue.status_id)
		local name = is_child and ("  " .. row_icon .. "  " .. label .. " " .. issue.title)
			or (label .. " " .. issue.title)

		return {
			icon = is_child and "" or row_icon,
			name = name,
			_key_label = label,
			comments = tostring(tonumber(issue.comment_count) or 0),
			assignee = person_value(issue.assignee, "Unassigned"),
			reporter = person_value(issue.reporter, "Unknown"),
			status = status_value(issue, opts),
		}
	end

	local function highlights(table_row, column, context)
		local issue = table_row._issue

		if issue == nil then
			return nil
		end

		---@cast issue GitHubIssue

		if column.key == "icon" then
			local icon, icon_highlight

			if issue.is_pinned == true then
				icon, icon_highlight = icons.general("pin")
			else
				icon, icon_highlight = state_icon(issue.status_id)
			end

			local start_col, end_col = context.text:find(icon, 1, true)

			if start_col then
				return { { start_col = start_col - 1, end_col = end_col, hl_group = icon_highlight } }
			end
		end

		if column.key == "name" then
			local spans = {}

			if (tonumber(table_row._tv2_depth) or 0) > 0 then
				local icon, icon_highlight = state_icon(issue.status_id)
				local start_col, end_col = context.text:find(icon, 1, true)

				if start_col then
					table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = icon_highlight })
				end
			end

			local label = table_row._key_label
			local start_col, end_col = context.text:find(label, 1, true)

			if start_col then
				table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = "AtlasTextMuted" })
				local title_start = end_col + 2

				if title_start <= #context.text then
					table.insert(spans, {
						start_col = title_start - 1,
						end_col = #context.text,
						hl_group = "Normal",
					})
				end
			end

			return #spans > 0 and spans or nil
		end

		if column.key == "comments" then
			return { { start_col = 0, end_col = #context.padded, hl_group = "AtlasTextMuted" } }
		end

		if column.key == "status" then
			local issue_key = issue.key
			local highlight = opts.reloading and opts.reloading[issue_key] and "AtlasTextMuted"
				or state_chip_highlight(issue.status_id)

			return { { start_col = 0, end_col = #context.padded, hl_group = highlight } }
		end

		if column.key == "assignee" then
			local name = issue.assignee and issue.assignee.name or nil

			return { { start_col = 0, end_col = #context.padded, hl_group = presentation.person_hl(name) } }
		end

		if column.key == "reporter" then
			local name = issue.reporter and issue.reporter.name or nil

			return { { start_col = 0, end_col = #context.padded, hl_group = presentation.person_hl(name) } }
		end
	end

	return render(opts, issues, {
		columns = columns,
		values = values,
		highlights = highlights,
	}, false)
end

function M.gitlab(opts, issues)
	local columns = {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue", min_width = 42 },

		{
			key = "assignee",
			name = string.format("%s Assignee", icons.general("user")),
			min_width = 10,
			max_width = 22,
			can_grow = false,
		},

		{
			key = "reporter",
			name = string.format("%s Reporter", icons.general("user")),
			min_width = 10,
			max_width = 22,
			can_grow = false,
		},

		{ key = "status", name = " Status", can_grow = false },
	}

	---@param issue GitLabIssue
	local function key_label(issue)
		return string.format("#%d", issue.iid)
	end

	local function values(issue, is_child)
		---@cast issue GitLabIssue
		local label = key_label(issue)
		local row_icon = state_icon(issue.status_id)

		return {
			icon = is_child and "" or row_icon,
			name = is_child and ("  " .. row_icon .. "  " .. label .. " " .. issue.title)
				or (label .. " " .. issue.title),
			_key_label = label,
			assignee = person_value(issue.assignee, "Unassigned"),
			reporter = person_value(issue.reporter, "Unknown"),
			status = status_value(issue, opts),
		}
	end

	local function highlights(table_row, column, context)
		local issue = table_row._issue

		if issue == nil then
			return nil
		end

		---@cast issue GitLabIssue

		if column.key == "icon" then
			local icon, icon_highlight

			if issue.is_pinned == true then
				icon, icon_highlight = icons.general("pin")
			else
				icon, icon_highlight = state_icon(issue.status_id)
			end

			local start_col, end_col = context.text:find(icon, 1, true)

			if start_col then
				return { { start_col = start_col - 1, end_col = end_col, hl_group = icon_highlight } }
			end
		end

		if column.key == "name" then
			local spans = {}

			if (tonumber(table_row._tv2_depth) or 0) > 0 then
				local icon, icon_highlight = state_icon(issue.status_id)
				local start_col, end_col = context.text:find(icon, 1, true)

				if start_col then
					table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = icon_highlight })
				end
			end

			local label = table_row._key_label
			local start_col, end_col = context.text:find(label, 1, true)

			if start_col then
				table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = "AtlasTextMuted" })
				local title_start = end_col + 2

				if title_start <= #context.text then
					table.insert(spans, {
						start_col = title_start - 1,
						end_col = #context.text,
						hl_group = "Normal",
					})
				end
			end

			return #spans > 0 and spans or nil
		end

		if column.key == "status" then
			local issue_key = issue.key
			local highlight = opts.reloading and opts.reloading[issue_key] and "AtlasTextMuted"
				or state_chip_highlight(issue.status_id)

			return { { start_col = 0, end_col = #context.padded, hl_group = highlight } }
		end

		if column.key == "assignee" then
			local name = issue.assignee and issue.assignee.name or nil

			return { { start_col = 0, end_col = #context.padded, hl_group = presentation.person_hl(name) } }
		end

		if column.key == "reporter" then
			local name = issue.reporter and issue.reporter.name or nil

			return { { start_col = 0, end_col = #context.padded, hl_group = presentation.person_hl(name) } }
		end
	end

	return render(opts, issues, {
		columns = columns,
		values = values,
		highlights = highlights,
	}, false)
end

function M.jira(opts, issues)
	local columns = {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue", min_width = 42 },

		{
			key = "assignee",
			name = string.format("%s Assignee", icons.general("user")),
			min_width = 10,
			max_width = 22,
			can_grow = false,
		},

		{
			key = "reporter",
			name = string.format("%s Reporter", icons.general("user")),
			min_width = 10,
			max_width = 22,
			can_grow = false,
		},

		{ key = "status", name = " Status", can_grow = false },
	}

	local function values(issue, is_child)
		---@cast issue JiraIssue
		local type_icon = icons.issues_type(issue.type and issue.type.name or nil)
		local title = is_child and (type_icon .. " " .. issue.key .. " " .. issue.title)
			or (issue.key .. " " .. issue.title)
		local priority_icon = icons.issues_priority(issue.priority)
		local due = utils.format_date(issue.duedate)
		local suffix = priority_icon

		if due ~= "" then
			local due_text = icons.general("created") .. " " .. due
			suffix = suffix ~= "" and (suffix .. "  " .. due_text) or due_text
		end

		local name = suffix ~= "" and (title .. "  " .. suffix) or title

		return {
			icon = is_child and "" or type_icon,
			name = is_child and ("  " .. name) or name,
			assignee = person_value(issue.assignee, "Unassigned"),
			reporter = person_value(issue.reporter, "Unknown"),
			status = status_value(issue, opts),
		}
	end

	local function highlights(table_row, column, context)
		local issue = table_row._issue

		if issue == nil then
			return nil
		end

		---@cast issue JiraIssue

		local issue_type = issue.type and issue.type.name or nil

		if column.key == "name" then
			local spans = {}

			if (tonumber(table_row._tv2_depth) or 0) > 0 then
				local icon, icon_highlight = icons.issues_type(issue_type)
				local start_col, end_col = context.text:find(icon, 1, true)

				if start_col then
					table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = icon_highlight })
				end
			end

			if issue.key ~= "" then
				local start_col, end_col = context.text:find(issue.key, 1, true)

				if start_col then
					local title_start = end_col + 2

					if title_start <= #context.text then
						table.insert(spans, {
							start_col = title_start - 1,
							end_col = #context.text,
							hl_group = "Normal",
						})
					end
					table.insert(spans, {
						start_col = start_col - 1,
						end_col = end_col,
						hl_group = presentation.issue_hl((tonumber(table_row._tv2_depth) or 0) > 0 and "" or issue.key),
					})
				end
			end

			if issue.priority and issue.priority ~= "" then
				local icon, icon_highlight = icons.issues_priority(issue.priority)
				local start_col, end_col = context.text:find(icon, 1, true)

				if start_col then
					table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = icon_highlight })
				end
			end

			return #spans > 0 and spans or nil
		end

		if column.key == "status" then
			local issue_key = issue.key
			local highlight = opts.reloading and opts.reloading[issue_key] and "AtlasTextMuted"
				or presentation.status_hl(issue.status_id)

			return { { start_col = 0, end_col = #context.padded, hl_group = highlight } }
		end

		if column.key == "icon" then
			local icon, icon_highlight = icons.issues_type(issue_type)
			local start_col, end_col = context.text:find(icon, 1, true)

			if start_col then
				return { { start_col = start_col - 1, end_col = end_col, hl_group = icon_highlight } }
			end
		end

		if column.key == "assignee" then
			local name = issue.assignee and issue.assignee.name or nil

			return { { start_col = 0, end_col = #context.padded, hl_group = presentation.person_hl(name) } }
		end

		if column.key == "reporter" then
			local name = issue.reporter and issue.reporter.name or nil

			return { { start_col = 0, end_col = #context.padded, hl_group = presentation.person_hl(name) } }
		end
	end

	return render(opts, issues, {
		columns = columns,
		values = values,
		highlights = highlights,
	}, true)
end

function M.default(opts, issues)
	local columns = {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue", min_width = 42 },

		{
			key = "assignee",
			name = string.format("%s Assignee", icons.general("user")),
			min_width = 10,
			max_width = 22,
			can_grow = false,
		},

		{
			key = "reporter",
			name = string.format("%s Reporter", icons.general("user")),
			min_width = 10,
			max_width = 22,
			can_grow = false,
		},

		{ key = "status", name = " Status", can_grow = false },
	}

	local function values(issue)
		return {
			icon = "",
			name = (issue.key or "") .. " " .. issue.title,
			assignee = (issue.assignee and issue.assignee.name) or "Unassigned",
			reporter = (issue.reporter and issue.reporter.name) or "Unknown",
			status = string.format(" %s ", issue.status or ""),
		}
	end

	local function highlights()
		return nil
	end

	return render(opts, issues, {
		columns = columns,
		values = values,
		highlights = highlights,
	}, false)
end

return M
