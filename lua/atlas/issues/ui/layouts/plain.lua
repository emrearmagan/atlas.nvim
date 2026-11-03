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
		{ key = "name", name = "Issue", min_width = 42 },
		{ key = "comments", name = icons.get("comment"), min_width = 2, can_grow = false },
		{ key = "assignee", name = icons.get("user") .. " Assignee", min_width = 10, max_width = 22, can_grow = false },
		{ key = "reporter", name = icons.get("user") .. " Reporter", min_width = 10, max_width = 22, can_grow = false },
		{ key = "status", name = " Status", can_grow = false },
	},
	values = function(issue, opts)
		---@cast issue GitHubIssue
		local label = string.format("#%d", issue.number)

		return {
			icon = github_issue_icon(issue),
			name = label .. " " .. issue.title,
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

		if column.key == "name" then
			local icon, icon_hl = github_issue_icon(issue)
			local spans = utils.key_title_highlights(context.text, row._key_label, "AtlasTextMuted")
			return utils.highlight_match(spans, context.text, icon, icon_hl)
		elseif column.key == "comments" then
			return "AtlasTextMuted"
		elseif column.key == "status" then
			return utils.status_hl(issue, opts, utils.state_chip_hl(issue.status_id))
		end

		return utils.person_hl(issue, column.key)
	end,
}

M.gitea = M.github
M.forgejo = M.github

M.gitlab = {
	columns = {
		{ key = "name", name = "Issue", min_width = 42 },
		{ key = "assignee", name = icons.get("user") .. " Assignee", min_width = 10, max_width = 22, can_grow = false },
		{ key = "reporter", name = icons.get("user") .. " Reporter", min_width = 10, max_width = 22, can_grow = false },
		{ key = "status", name = " Status", can_grow = false },
	},
	values = function(issue, opts)
		---@cast issue GitLabIssue
		local label = string.format("#%d", issue.iid)

		return {
			icon = utils.state_icon(issue.status_id),
			name = label .. " " .. issue.title,
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

		if column.key == "name" then
			local icon, icon_hl = utils.state_icon(issue.status_id)
			local spans = utils.key_title_highlights(context.text, row._key_label, "AtlasTextMuted")
			return utils.highlight_match(spans, context.text, icon, icon_hl)
		elseif column.key == "status" then
			return utils.status_hl(issue, opts, utils.state_chip_hl(issue.status_id))
		end

		return utils.person_hl(issue, column.key)
	end,
}

M.jira = {
	tree_indicator = true,
	columns = {
		{ key = "name", name = "Issue", min_width = 42 },
		{ key = "assignee", name = icons.get("user") .. " Assignee", min_width = 10, max_width = 22, can_grow = false },
		{ key = "reporter", name = icons.get("user") .. " Reporter", min_width = 10, max_width = 22, can_grow = false },
		{ key = "status", name = " Status", can_grow = false },
	},
	values = function(issue, opts)
		---@cast issue JiraIssue
		local priority = icons.get(issue.priority or "", "priority")

		return {
			icon = utils.type_icon(issue),
			name = utils.join({ issue.key .. " " .. issue.title, priority, utils.due_text(issue) }),
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

		if column.key == "name" then
			local icon, icon_hl = utils.type_icon(issue)
			local key_hl = presentation.issue_hl(row._is_child and "" or issue.key)
			local spans = utils.key_title_highlights(context.text, issue.key, key_hl)
			utils.highlight_match(spans, context.text, icon, icon_hl)
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

M.default = {
	columns = {
		{ key = "name", name = "Issue", min_width = 42 },
		{ key = "assignee", name = icons.get("user") .. " Assignee", min_width = 10, max_width = 22, can_grow = false },
		{ key = "reporter", name = icons.get("user") .. " Reporter", min_width = 10, max_width = 22, can_grow = false },
		{ key = "status", name = " Status", can_grow = false },
	},
	values = function(issue)
		return {
			icon = "",
			name = (issue.key or "") .. " " .. issue.title,
			assignee = issue.assignee and presentation.person_name(issue.assignee) or "Unassigned",
			reporter = presentation.person_name(issue.reporter),
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
	local child_indent = provider.tree_indicator and "    " or "  "
	local rows = {}
	local show_indicator = false

	local function issue_row(issue, prefix, fold, fold_hl)
		local row = provider.values(issue, opts)
		local icon = fold or row.icon
		local star = issue.is_starred and (STAR_ICON .. " ") or ""
		row.name = prefix .. (icon ~= "" and (icon .. " ") or "") .. star .. row.name
		row._fold_icon, row._fold_icon_hl = fold, fold_hl
		row._item = { kind = "issue", issue = issue }
		row._issue = issue
		row._is_child = prefix ~= ""
		row.children = {}

		return row
	end

	for _, group in ipairs(groups) do
		local fold, fold_hl
		if #group.children > 0 then
			if provider.tree_indicator then
				show_indicator = true
			else
				fold, fold_hl = icons.get(collapsed[group.issue.key] and "fold_closed" or "fold_open")
			end
		end

		local row = issue_row(group.issue, "", fold, fold_hl)
		for _, child in ipairs(group.children) do
			table.insert(row.children, issue_row(child, child_indent))
		end
		table.insert(rows, row)
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
			column_key = "name",
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
			local spans = provider.highlights and provider.highlights(row, column, context, opts) or nil
			if column.key == "name" and row._issue then
				spans = spans or {}
				if row._fold_icon then
					utils.highlight_match(spans, context.text, row._fold_icon, row._fold_icon_hl)
				end
				if row._issue.is_starred then
					utils.highlight_match(spans, context.text, STAR_ICON, STAR_HIGHLIGHT)
				end
			end

			return spans
		end,
	})
end

return M
