local table_tree = require("atlas.ui.components.table_tree")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local presentation = require("atlas.issues.ui.presentation")

local M = {}

local STAR_ICON, STAR_ICON_HL = icons.get("star")

local function person_value(user, fallback)
	local name = user and user.name or fallback
	return string.format("%s %s", icons.get("user"), utils.shorten_name(name, 20))
end

local function person_highlight(issue, column, context)
	if column.key == "assignee" then
		local name = issue.assignee and issue.assignee.name or nil
		return { { start_col = 0, end_col = #context.padded, hl_group = presentation.person_hl(name) } }
	end

	if column.key == "reporter" then
		local name = issue.reporter and issue.reporter.name or nil
		return { { start_col = 0, end_col = #context.padded, hl_group = presentation.person_hl(name) } }
	end
end

local function status_value(issue, opts)
	if opts.reloading and opts.reloading[issue.key] then
		return string.format(" %s ", opts.spinner)
	end

	return string.format(" %s ", issue.status or "")
end

local function state_icon(status_id)
	if status_id == "closed" then
		return icons.get("successful", "status"), "AtlasIssueClosed"
	end

	return icons.get("issue"), "AtlasIssueOpen"
end

local function meta_text(issue, parts)
	local due = utils.format_date(issue.duedate)

	if due ~= "" then
		table.insert(parts, string.format("%s %s", icons.get("created"), due))
	end

	if issue.story_points ~= nil then
		table.insert(parts, string.format("%s pts", tostring(issue.story_points)))
	end

	return table.concat(parts, "  ")
end

local function blank_row(columns)
	local row = {}

	for _, column in ipairs(columns) do
		row[column.key] = ""
	end

	return row
end

local function render(opts, issues, columns, values, highlights)
	local rows = {}

	for _, issue in ipairs(issues) do
		local row = values(issue)

		if issue.is_starred then
			row.name = STAR_ICON .. " " .. row.name
		end

		row._item = { kind = "issue", key = issue.key, _issue = issue }
		row._issue = issue
		table.insert(rows, row)

		if row._meta ~= "" then
			local metadata_row = blank_row(columns)
			metadata_row.kind = "meta"
			metadata_row.name = row._meta
			metadata_row.separator = true
			metadata_row._item = { kind = "issue_meta", key = issue.key, _issue = issue }
			table.insert(rows, metadata_row)
		else
			row.separator = true
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
		cell_hl = function(row, column, context)
			if row.kind == "meta" then
				return { { start_col = 0, end_col = #context.padded, hl_group = "AtlasTextMuted" } }
			end

			local spans = highlights and highlights(row, column, context) or nil
			if column.key == "name" and row._issue and row._issue.is_starred then
				spans = spans or {}
				table.insert(spans, 1, { start_col = 0, end_col = #STAR_ICON, hl_group = STAR_ICON_HL })
			end

			return spans
		end,
	})
end

---@param opts table
---@param issues GitHubIssue[]
---@return string[], table<integer, table>, table[]
function M.github(opts, issues)
	local columns = {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue", min_width = 42 },
		{
			key = "comments",
			name = icons.get("comment"),
			min_width = 2,
			can_grow = false,
		},
		{
			key = "assignee",
			name = string.format("%s Assignee", icons.get("user")),
			min_width = 10,
			max_width = 22,
			can_grow = false,
		},
		{
			key = "reporter",
			name = string.format("%s Reporter", icons.get("user")),
			min_width = 10,
			max_width = 22,
			can_grow = false,
		},
		{ key = "created", name = icons.get("created"), can_grow = false },
		{ key = "updated", name = icons.get("updated"), can_grow = false },
		{ key = "status", name = " Status", can_grow = false },
	}

	local function values(issue)
		local label = string.format("#%d", issue.number)
		local metadata = issue.repo_full_name

		if metadata == nil then
			local type_name = issue.type and issue.type.name or ""
			metadata = meta_text(issue, type_name ~= "" and { type_name } or {})
		end

		return {
			icon = issue.is_pinned == true and icons.get("pin") or state_icon(issue.status_id),
			name = label .. " " .. issue.title,
			_key_label = label,
			comments = tostring(tonumber(issue.comment_count) or 0),
			assignee = person_value(issue.assignee, "Unassigned"),
			reporter = person_value(issue.reporter, "Unknown"),
			status = status_value(issue, opts),
			created = utils.relative_time(issue.created_at),
			updated = utils.relative_time(issue.updated_at),
			_meta = metadata,
		}
	end

	local function highlights(row, column, context)
		local issue = row._issue
		if issue == nil then
			return nil
		end

		if column.key == "icon" then
			local icon, hl_group
			if issue.is_pinned == true then
				icon, hl_group = icons.get("pin")
			else
				icon, hl_group = state_icon(issue.status_id)
			end

			local start_col, end_col = context.text:find(icon, 1, true)
			if start_col then
				return { { start_col = start_col - 1, end_col = end_col, hl_group = hl_group } }
			end
		end

		if column.key == "name" then
			local spans = {}
			local start_col, end_col = context.text:find(row._key_label, 1, true)
			if start_col then
				table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = "AtlasTextMuted" })
				local title_start = end_col + 2
				if title_start <= #context.text then
					table.insert(spans, { start_col = title_start - 1, end_col = #context.text, hl_group = "Normal" })
				end
			end

			return #spans > 0 and spans or nil
		end

		if column.key == "comments" or column.key == "created" or column.key == "updated" then
			return { { start_col = 0, end_col = #context.padded, hl_group = "AtlasTextMuted" } }
		end

		if column.key == "status" then
			local hl_group = opts.reloading and opts.reloading[issue.key] and "AtlasTextMuted"
				or (issue.status_id == "closed" and "AtlasIssueClosedChip" or "AtlasIssueOpenChip")
			return { { start_col = 0, end_col = #context.padded, hl_group = hl_group } }
		end

		return person_highlight(issue, column, context)
	end

	return render(opts, issues, columns, values, highlights)
end

---@param opts table
---@param issues GitLabIssue[]
---@return string[], table<integer, table>, table[]
function M.gitlab(opts, issues)
	local columns = {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue", min_width = 42 },
		{
			key = "assignee",
			name = string.format("%s Assignee", icons.get("user")),
			min_width = 10,
			max_width = 22,
			can_grow = false,
		},
		{
			key = "reporter",
			name = string.format("%s Reporter", icons.get("user")),
			min_width = 10,
			max_width = 22,
			can_grow = false,
		},
		{ key = "status", name = " Status", can_grow = false },
	}

	local function values(issue)
		local parts = {}

		if issue.project_path and issue.project_path ~= "" then
			table.insert(parts, issue.project_path)
		end

		local type_name = issue.type and issue.type.name or ""
		if type_name ~= "" then
			table.insert(parts, type_name)
		end

		local label = string.format("#%d", issue.iid)
		return {
			icon = state_icon(issue.status_id),
			name = label .. " " .. issue.title,
			_key_label = label,
			assignee = person_value(issue.assignee, "Unassigned"),
			reporter = person_value(issue.reporter, "Unknown"),
			status = status_value(issue, opts),
			_meta = meta_text(issue, parts),
		}
	end

	local function highlights(row, column, context)
		local issue = row._issue
		if issue == nil then
			return nil
		end

		if column.key == "icon" then
			local icon, hl_group
			if issue.is_pinned == true then
				icon, hl_group = icons.get("pin")
			else
				icon, hl_group = state_icon(issue.status_id)
			end

			local start_col, end_col = context.text:find(icon, 1, true)
			if start_col then
				return { { start_col = start_col - 1, end_col = end_col, hl_group = hl_group } }
			end
		end

		if column.key == "name" then
			local spans = {}
			local start_col, end_col = context.text:find(row._key_label, 1, true)
			if start_col then
				table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = "AtlasTextMuted" })
				local title_start = end_col + 2
				if title_start <= #context.text then
					table.insert(spans, { start_col = title_start - 1, end_col = #context.text, hl_group = "Normal" })
				end
			end

			return #spans > 0 and spans or nil
		end

		if column.key == "status" then
			local hl_group = opts.reloading and opts.reloading[issue.key] and "AtlasTextMuted"
				or (issue.status_id == "closed" and "AtlasIssueClosedChip" or "AtlasIssueOpenChip")
			return { { start_col = 0, end_col = #context.padded, hl_group = hl_group } }
		end

		return person_highlight(issue, column, context)
	end

	return render(opts, issues, columns, values, highlights)
end

---@param opts table
---@param issues JiraIssue[]
---@return string[], table<integer, table>, table[]
function M.jira(opts, issues)
	local columns = {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue", min_width = 42 },
		{
			key = "assignee",
			name = string.format("%s Assignee", icons.get("user")),
			min_width = 10,
			max_width = 22,
			can_grow = false,
		},
		{
			key = "reporter",
			name = string.format("%s Reporter", icons.get("user")),
			min_width = 10,
			max_width = 22,
			can_grow = false,
		},
		{ key = "status", name = " Status", can_grow = false },
	}

	local function values(issue)
		local type_name = issue.type and issue.type.name or ""
		local parts = {}

		if type_name ~= "" then
			table.insert(parts, type_name)
		end

		if issue.priority and issue.priority ~= "" then
			table.insert(parts, issue.priority)
		end

		local title = issue.key .. " " .. issue.title
		local suffix = icons.get(issue.priority or "", "priority")
		local due = utils.format_date(issue.duedate)

		if due ~= "" then
			local due_text = icons.get("created") .. " " .. due
			suffix = suffix ~= "" and (suffix .. "  " .. due_text) or due_text
		end

		return {
			icon = issue.icon and issue.icon.icon or icons.get("issue"),
			name = suffix ~= "" and (title .. "  " .. suffix) or title,
			assignee = person_value(issue.assignee, "Unassigned"),
			reporter = person_value(issue.reporter, "Unknown"),
			status = status_value(issue, opts),
			_meta = meta_text(issue, parts),
		}
	end

	local function highlights(row, column, context)
		local issue = row._issue
		if issue == nil then
			return nil
		end

		if column.key == "name" then
			local spans = {}
			if issue.key ~= "" then
				local start_col, end_col = context.text:find(issue.key, 1, true)
				if start_col then
					local title_start = end_col + 2
					if title_start <= #context.text then
						table.insert(
							spans,
							{ start_col = title_start - 1, end_col = #context.text, hl_group = "Normal" }
						)
					end
					table.insert(spans, {
						start_col = start_col - 1,
						end_col = end_col,
						hl_group = presentation.issue_hl(issue.key),
					})
				end
			end

			if issue.priority and issue.priority ~= "" then
				local icon, hl_group = icons.get(issue.priority, "priority")
				local start_col, end_col = context.text:find(icon, 1, true)
				if start_col then
					table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = hl_group })
				end
			end

			return #spans > 0 and spans or nil
		end

		if column.key == "status" then
			local hl_group = opts.reloading and opts.reloading[issue.key] and "AtlasTextMuted"
				or presentation.status_hl(issue.status_id)
			return { { start_col = 0, end_col = #context.padded, hl_group = hl_group } }
		end

		if column.key == "icon" then
			local icon, hl_group = icons.get("issue")
			if issue.icon then
				icon = issue.icon.icon
				hl_group = issue.icon.hl_group or hl_group
			end

			local start_col, end_col = context.text:find(icon, 1, true)
			if start_col then
				return { { start_col = start_col - 1, end_col = end_col, hl_group = hl_group } }
			end
		end

		return person_highlight(issue, column, context)
	end

	return render(opts, issues, columns, values, highlights)
end

---@param opts table
---@param issues Issue[]
---@return string[], table<integer, table>, table[]
function M.default(opts, issues)
	local columns = {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue", min_width = 42 },
		{
			key = "assignee",
			name = string.format("%s Assignee", icons.get("user")),
			min_width = 10,
			max_width = 22,
			can_grow = false,
		},
		{
			key = "reporter",
			name = string.format("%s Reporter", icons.get("user")),
			min_width = 10,
			max_width = 22,
			can_grow = false,
		},
		{ key = "status", name = " Status", can_grow = false },
	}

	local function values(issue)
		local parts = {}
		local type_name = issue.type and issue.type.name or ""
		if type_name ~= "" then
			table.insert(parts, type_name)
		end

		return {
			icon = "",
			name = (issue.key or "") .. " " .. issue.title,
			assignee = (issue.assignee and issue.assignee.name) or "Unassigned",
			reporter = (issue.reporter and issue.reporter.name) or "Unknown",
			status = string.format(" %s ", issue.status or ""),
			_meta = meta_text(issue, parts),
		}
	end

	local function highlights() end

	return render(opts, issues, columns, values, highlights)
end

return M
