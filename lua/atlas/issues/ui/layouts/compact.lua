local presentation = require("atlas.issues.ui.presentation")
local table_tree = require("atlas.ui.components.table_tree")
local icons = require("atlas.ui.shared.icons")
local ui_utils = require("atlas.ui.shared.utils")
local utils = require("atlas.issues.ui.layouts.utils")

local M = {}

local STAR_ICON, STAR_HIGHLIGHT = icons.get("star")

---@param issue Issue
---@param parts string[]
---@return string
local function meta_text(issue, parts)
	table.insert(parts, utils.due_text(issue))
	if issue.story_points ~= nil then
		table.insert(parts, tostring(issue.story_points) .. " pts")
	end

	return utils.join(parts)
end

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
		{ key = "created", name = icons.get("created"), can_grow = false },
		{ key = "updated", name = icons.get("updated"), can_grow = false },
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
			created = ui_utils.relative_time(issue.created_at),
			updated = ui_utils.relative_time(issue.updated_at),
			_meta = issue.repo_full_name or meta_text(issue, { issue.type and issue.type.name or "" }),
		}
	end,
	highlights = function(row, column, context, opts)
		local issue = row._issue
		if issue == nil then
			return nil
		end
		---@cast issue GitHubIssue

		if column.key == "icon" then
			local icon, icon_hl = github_issue_icon(issue)
			return utils.highlight_match({}, context.text, icon, icon_hl)
		elseif column.key == "name" then
			return utils.key_title_highlights(context.text, row._key_label, "AtlasTextMuted")
		elseif column.key == "comments" or column.key == "created" or column.key == "updated" then
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
			_meta = meta_text(issue, { issue.project_path or "", issue.type and issue.type.name or "" }),
		}
	end,
	highlights = function(row, column, context, opts)
		local issue = row._issue
		if issue == nil then
			return nil
		end

		if column.key == "icon" then
			local icon, icon_hl = utils.state_icon(issue.status_id)
			return utils.highlight_match({}, context.text, icon, icon_hl)
		elseif column.key == "name" then
			return utils.key_title_highlights(context.text, row._key_label, "AtlasTextMuted")
		elseif column.key == "status" then
			return utils.status_hl(issue, opts, utils.state_chip_hl(issue.status_id))
		end

		return utils.person_hl(issue, column.key)
	end,
}

M.jira = {
	columns = {
		{ key = "icon", name = "", can_grow = false, align = "center" },
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
			_meta = meta_text(issue, { issue.type and issue.type.name or "", issue.priority or "" }),
		}
	end,
	highlights = function(row, column, context, opts)
		local issue = row._issue
		if issue == nil then
			return nil
		end
		---@cast issue JiraIssue

		if column.key == "icon" then
			local icon, icon_hl = utils.type_icon(issue)
			return utils.highlight_match({}, context.text, icon, icon_hl)
		elseif column.key == "name" then
			local spans = utils.key_title_highlights(context.text, issue.key, presentation.issue_hl(issue.key))
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

M.shortcut = {
	columns = {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue", min_width = 42 },
		{ key = "assignee", name = icons.get("user") .. " Assignee", min_width = 10, max_width = 22, can_grow = false },
		{ key = "reporter", name = icons.get("user") .. " Reporter", min_width = 10, max_width = 22, can_grow = false },
		{ key = "status", name = " Status", can_grow = false },
	},
	values = function(issue, opts)
		---@cast issue ShortcutIssue
		local label = "#" .. issue.key
		local labels = {}
		for _, item in ipairs(issue.labels) do
			table.insert(labels, item.name)
		end

		local points = issue.story_points ~= nil and (tostring(issue.story_points) .. " pts") or ""
		local tags = #labels > 0 and (icons.get("tag") .. " " .. table.concat(labels, ", ")) or ""
		local comments = (issue.comment_count or 0) > 0 and (icons.get("comment") .. " " .. issue.comment_count) or ""

		local assignee = utils.person_value(issue.assignee, "Unassigned")
		if #issue.owner_ids > 1 then
			assignee = string.format("%s +%d", assignee, #issue.owner_ids - 1)
		end

		return {
			icon = utils.type_icon(issue),
			name = label .. " " .. issue.title,
			_key_label = label,
			assignee = assignee,
			reporter = utils.person_value(issue.reporter, "Unknown"),
			status = utils.status_value(issue, opts),
			_meta = utils.join({ issue.type.name, points, utils.due_text(issue), tags, comments }),
		}
	end,
	highlights = function(row, column, context, opts)
		local issue = row._issue
		if issue == nil then
			return nil
		end
		---@cast issue ShortcutIssue

		if column.key == "icon" then
			local icon, icon_hl = utils.type_icon(issue)
			return utils.highlight_match({}, context.text, icon, icon_hl)
		elseif column.key == "name" then
			return utils.highlight_match({}, context.text, row._key_label, "AtlasTextMuted")
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
			_meta = meta_text(issue, { issue.type and issue.type.name or "" }),
		}
	end,
}

---@param opts table
---@param issues Issue[]
---@param provider table
---@return string[], table<integer, table>, table[]
function M.render(opts, issues, provider)
	local rows = {}

	for _, issue in ipairs(issues) do
		local row = provider.values(issue, opts)
		if issue.is_starred then
			row.name = STAR_ICON .. " " .. row.name
		end

		row._item = { kind = "issue", key = issue.key, _issue = issue }
		row._issue = issue
		table.insert(rows, row)

		if row._meta ~= "" then
			local meta = utils.blank_row(provider.columns)
			meta.kind = "meta"
			meta.name = row._meta
			meta.separator = true
			meta._item = { kind = "issue_meta", key = issue.key, _issue = issue }
			table.insert(rows, meta)
		else
			row.separator = true
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
		cell_hl = function(row, column, context)
			if row.kind == "meta" then
				return "AtlasTextMuted"
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
