local presentation = require("atlas.issues.ui.presentation")
local table_tree = require("atlas.ui.components.table_tree")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.issues.ui.layouts.utils")

local M = {}

local STAR_ICON, STAR_HIGHLIGHT = icons.get("star")

---@param issue GitHubIssue
---@return string, string
local function github_issue_icon(issue)
	if issue.is_pinned then
		return icons.get("pin")
	end

	return utils.state_icon(issue.status_id)
end

M.github = {
	columns = {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue", min_width = 42 },
		{ key = "comments", name = icons.get("comment"), min_width = 2, can_grow = false },
		{ key = "assignee", name = icons.get("user") .. " Assignee", min_width = 10, max_width = 22, can_grow = false },
		{ key = "reporter", name = icons.get("user") .. " Reporter", min_width = 10, max_width = 22, can_grow = false },
		{ key = "status", name = " Status", can_grow = false },
	},
	values = function(issue, opts, is_child)
		---@cast issue GitHubIssue
		local label = string.format("#%d", issue.number)
		local icon = github_issue_icon(issue)

		return {
			icon = is_child and "" or icon,
			name = (is_child and "  " .. icon .. "  " or "") .. label .. " " .. issue.title,
			_key_label = label,
			comments = tostring(tonumber(issue.comment_count) or 0),
			assignee = utils.person_value(issue.assignee, "Unassigned"),
			reporter = utils.person_value(issue.reporter, "Unknown"),
			status = utils.status_value(issue, opts),
		}
	end,
	highlights = function(row, column, context, opts)
		local issue = row._issue
		if issue == nil then
			return nil
		end
		---@cast issue GitHubIssue

		local icon, icon_hl = github_issue_icon(issue)
		if column.key == "icon" then
			return utils.highlight_match({}, context.text, icon, icon_hl)
		elseif column.key == "name" then
			local spans = utils.key_title_highlights(context.text, row._key_label, "AtlasTextMuted")
			if row._is_child then
				utils.highlight_match(spans, context.text, icon, icon_hl)
			end
			return spans
		elseif column.key == "comments" then
			return "AtlasTextMuted"
		elseif column.key == "status" then
			return utils.status_hl(issue, opts, utils.state_chip_hl(issue.status_id))
		end

		return utils.person_hl(issue, column.key)
	end,
}

M.gitlab = {
	columns = {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue", min_width = 42 },
		{ key = "assignee", name = icons.get("user") .. " Assignee", min_width = 10, max_width = 22, can_grow = false },
		{ key = "reporter", name = icons.get("user") .. " Reporter", min_width = 10, max_width = 22, can_grow = false },
		{ key = "status", name = " Status", can_grow = false },
	},
	values = function(issue, opts, is_child)
		---@cast issue GitLabIssue
		local label = string.format("#%d", issue.iid)
		local icon = utils.state_icon(issue.status_id)

		return {
			icon = is_child and "" or icon,
			name = (is_child and "  " .. icon .. "  " or "") .. label .. " " .. issue.title,
			_key_label = label,
			assignee = utils.person_value(issue.assignee, "Unassigned"),
			reporter = utils.person_value(issue.reporter, "Unknown"),
			status = utils.status_value(issue, opts),
		}
	end,
	highlights = function(row, column, context, opts)
		local issue = row._issue
		if issue == nil then
			return nil
		end

		local icon, icon_hl = utils.state_icon(issue.status_id)
		if column.key == "icon" then
			return utils.highlight_match({}, context.text, icon, icon_hl)
		elseif column.key == "name" then
			local spans = utils.key_title_highlights(context.text, row._key_label, "AtlasTextMuted")
			if row._is_child then
				utils.highlight_match(spans, context.text, icon, icon_hl)
			end
			return spans
		elseif column.key == "status" then
			return utils.status_hl(issue, opts, utils.state_chip_hl(issue.status_id))
		end

		return utils.person_hl(issue, column.key)
	end,
}

M.jira = {
	tree_indicator = true,
	columns = {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue", min_width = 42 },
		{ key = "assignee", name = icons.get("user") .. " Assignee", min_width = 10, max_width = 22, can_grow = false },
		{ key = "reporter", name = icons.get("user") .. " Reporter", min_width = 10, max_width = 22, can_grow = false },
		{ key = "status", name = " Status", can_grow = false },
	},
	values = function(issue, opts, is_child)
		---@cast issue JiraIssue
		local icon = utils.type_icon(issue)
		local priority = icons.get(issue.priority or "", "priority")
		local title = utils.join({ issue.key .. " " .. issue.title, priority, utils.due_text(issue) })

		return {
			icon = is_child and "" or icon,
			name = (is_child and "  " .. icon .. " " or "") .. title,
			assignee = utils.person_value(issue.assignee, "Unassigned"),
			reporter = utils.person_value(issue.reporter, "Unknown"),
			status = utils.status_value(issue, opts),
		}
	end,
	highlights = function(row, column, context, opts)
		local issue = row._issue
		if issue == nil then
			return nil
		end
		---@cast issue JiraIssue

		local icon, icon_hl = utils.type_icon(issue)
		if column.key == "icon" then
			return utils.highlight_match({}, context.text, icon, icon_hl)
		elseif column.key == "name" then
			local key_hl = presentation.issue_hl(row._is_child and "" or issue.key)
			local spans = utils.key_title_highlights(context.text, issue.key, key_hl)
			if row._is_child then
				utils.highlight_match(spans, context.text, icon, icon_hl)
			end
			if issue.priority and issue.priority ~= "" then
				local priority, priority_hl = icons.get(issue.priority, "priority")
				utils.highlight_match(spans, context.text, priority, priority_hl)
			end
			return spans
		elseif column.key == "status" then
			return utils.status_hl(issue, opts, presentation.status_hl(issue.status_id))
		end

		return utils.person_hl(issue, column.key)
	end,
}

M.azure = {
	columns = {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue", min_width = 42 },
		{ key = "assignee", name = icons.get("user") .. " Assignee", min_width = 10, max_width = 22, can_grow = false },
		{ key = "reporter", name = icons.get("user") .. " Reporter", min_width = 10, max_width = 22, can_grow = false },
		{ key = "status", name = " Status", can_grow = false },
	},
	values = function(issue, opts, is_child)
		local icon = icons.get("issue")

		return {
			icon = is_child and "" or icon,
			name = (is_child and "  " .. icon .. " " or "") .. issue.key .. " " .. issue.title,
			assignee = utils.person_value(issue.assignee, "Unassigned"),
			reporter = utils.person_value(issue.reporter, "Unknown"),
			status = utils.status_value(issue, opts),
		}
	end,
	highlights = function(row, column, _, opts)
		local issue = row._issue
		if issue == nil then
			return nil
		end

		if column.key == "icon" then
			local _, icon_hl = icons.get("issue")
			return icon_hl
		elseif column.key == "status" then
			return utils.status_hl(issue, opts, presentation.status_hl(issue.status_id))
		end

		return utils.person_hl(issue, column.key)
	end,
}

M.default = {
	columns = {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue", min_width = 42 },
		{ key = "assignee", name = icons.get("user") .. " Assignee", min_width = 10, max_width = 22, can_grow = false },
		{ key = "reporter", name = icons.get("user") .. " Reporter", min_width = 10, max_width = 22, can_grow = false },
		{ key = "status", name = " Status", can_grow = false },
	},
	values = function(issue)
		return {
			icon = "",
			name = (issue.key or "") .. " " .. issue.title,
			assignee = issue.assignee and issue.assignee.name or "Unassigned",
			reporter = issue.reporter and issue.reporter.name or "Unknown",
			status = string.format(" %s ", issue.status or ""),
		}
	end,
}

---@param opts table
---@param issues Issue[]
---@param provider table
---@return string[], table<integer, table>, table[]
function M.render(opts, issues, provider)
	local groups = opts.groups
	if groups == nil then
		groups = {}
		for _, issue in ipairs(issues) do
			table.insert(groups, { issue = issue, children = {} })
		end
	end

	local collapsed = opts.collapsed or {}
	local rows = {}
	local show_indicator = false

	local function issue_row(issue, is_child)
		local row = provider.values(issue, opts, is_child)
		if issue.is_starred then
			row.name = STAR_ICON .. " " .. row.name
		end

		row._item = { kind = "issue", key = issue.key, _issue = issue }
		row._issue = issue
		row._is_child = is_child
		row.children = {}

		return row
	end

	for index, group in ipairs(groups) do
		local row = issue_row(group.issue, false)

		for _, child in ipairs(group.children) do
			table.insert(row.children, issue_row(child, true))
		end

		if #group.children > 0 then
			if provider.tree_indicator then
				show_indicator = true
			else
				row.icon, row._fold_icon_hl = icons.get(collapsed[group.issue.key] and "fold_closed" or "fold_open")
			end
		end

		table.insert(rows, row)

		if index < #groups then
			local separator = utils.blank_row(provider.columns)
			separator.kind = "separator"
			table.insert(rows, separator)
		end
	end

	if opts.loading then
		utils.append_loading(rows, provider.columns, opts.spinner)
	end

	return table_tree.render({
		width = opts.width,
		margin = 1,
		columns = provider.columns,
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
		cell_hl = function(row, column, context)
			if column.key == "icon" and row._fold_icon_hl then
				return row._fold_icon_hl
			end

			local spans = provider.highlights and provider.highlights(row, column, context, opts) or nil
			if column.key == "name" and row._issue and row._issue.is_starred then
				spans = spans or {}
				table.insert(spans, 1, { start_col = 0, end_col = #STAR_ICON, hl_group = STAR_HIGHLIGHT })
			end

			return spans
		end,
	})
end

return M
