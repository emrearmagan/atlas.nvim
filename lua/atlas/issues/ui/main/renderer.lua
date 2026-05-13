local M = {}

local resolver = require("atlas.core.keymaps")
local state = require("atlas.issues.state")
local header = require("atlas.ui.components.header")
local navbar = require("atlas.ui.components.navbar")
local table_tree = require("atlas.ui.components.table_tree")
local utils = require("atlas.ui.shared.utils")
local footer = require("atlas.ui.components.footer")
local helper = require("atlas.issues.ui.main.helper")
local icons = require("atlas.ui.shared.icons")

---@param view IssuesViewConfig|nil
---@return string
local function view_id(view)
	if view == nil then
		return ""
	end
	return view.key or view.name or ""
end

---@param action_id AtlasKeymapActionId|string
---@param fallback string
---@return string
local function key_label(action_id, fallback)
	local keys = resolver.resolve(action_id)
	if type(keys) == "table" and #keys > 0 then
		return tostring(keys[1])
	end
	return fallback
end

---@param view IssuesViewConfig|nil
---@return string
local function search_text(view)
	if type(view) ~= "table" then
		return ""
	end

	local provider_id = state.provider and state.provider.id or ""
	if provider_id == "github" then
		local search = tostring(view.search or "")
		if search ~= "" and not search:lower():find("is:issue", 1, true) then
			search = search .. " is:issue"
		end
		return search
	end

	local jql = tostring(view.jql or "")
	if jql ~= "" then
		return jql
	end

	return tostring(view.search or "")
end

---@param lines string[]
---@param spans table[]
---@param text string
local function append_search_text(lines, spans, text)
	if text == "" then
		return
	end

	local line = string.format(" %s %s", icons.general("search"), text)
	table.insert(lines, line)
	table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #line, hl_group = "AtlasTextMuted" })
	table.insert(lines, "")
end

---@param issue Issue
---@param is_child boolean|nil
---@return table
local function issue_to_row(issue, is_child)
	local provider = state.provider
	local row_data
	if provider and provider.format_row then
		row_data = provider.format_row(issue, is_child == true)
	end
	if row_data == nil then
		row_data = {
			icon = "",
			name = (issue.key or "") .. " " .. (issue.summary or ""),
			assignee = (type(issue.assignee) == "table" and issue.assignee.display_name) or "Unassigned",
			reporter = (type(issue.reporter) == "table" and issue.reporter.display_name) or "Unknown",
			status = string.format(" %s ", issue.status or ""),
		}
	end

	row_data._item = { kind = "issue", key = issue.key, _issue = issue }
	row_data._issue = issue
	row_data.children = row_data.children or {}
	return row_data
end

---@param issue_groups IssuesGroup[]
---@return table[]
local function issues_to_rows(issue_groups)
	local rows = {}
	for i, group in ipairs(issue_groups) do
		local children = group.children or {}
		local root_row = issue_to_row(group.issue, false)

		for _, child in ipairs(children) do
			table.insert(root_row.children, issue_to_row(child, true))
		end

		table.insert(rows, root_row)

		if i < #issue_groups then
			table.insert(rows, {
				kind = "separator",
				icon = "",
				name = "",
				assignee = "",
				reporter = "",
				status = "",
				children = {},
			})
		end
	end
	return rows
end

---@param issue_groups IssuesGroup[]
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

local cell_hl

---@param opts { width: integer }
---@param issue_groups IssuesGroup[]
---@return string[], table<integer, table>, table[]
local function render_issue_table(opts, issue_groups)
	local rows = issues_to_rows(issue_groups)
	local show_tree_indicator = should_show_indicator(issue_groups)
	if state.is_loading then
		table.insert(rows, {
			icon = "",
			name = "",
			assignee = "",
			reporter = "",
			status = "",
		})
		table.insert(rows, {
			icon = state.reload_spinner_frame or "⠋",
			name = "Loading...",
			assignee = "",
			reporter = "",
			status = "",
		})
	end

	return table_tree.render({
		width = opts.width,
		margin = 1,
		columns = {
			{ key = "icon", name = "", can_grow = false, align = "center" },
			{ key = "name", name = "Issue" },
			{
				key = "assignee",
				name = string.format("%s Assignee", icons.general("user")),
				max_width = 22,
				can_grow = false,
			},
			{
				key = "reporter",
				name = string.format("%s Reporter", icons.general("user")),
				max_width = 22,
				can_grow = false,
			},
			{ key = "status", name = " Status", can_grow = false },
		},
		rows = rows,
		tree = {
			column_key = "icon",
			children_key = "children",
			default_expanded = true,
			indent = "",
			show_indicator = show_tree_indicator,
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
end

---@param issue Issue
---@return string
local function issue_project_label(issue)
	local project = type(issue) == "table" and issue.project or nil
	if type(project) == "table" then
		local key = tostring(project.key or "")
		if key ~= "" then
			return key
		end

		local name = tostring(project.name or "")
		if name ~= "" then
			return name
		end
	end

	local key = tostring(type(issue) == "table" and issue.key or "")
	local prefix = key:match("^([A-Z][A-Z0-9]+)%-%d+$") or key:match("^([^%-]+)%-")
	if prefix and prefix ~= "" then
		return prefix
	end

	return "Issues"
end

---@return table[]
local function compact_columns()
	return {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue" },
		{
			key = "assignee",
			name = string.format("%s Assignee", icons.general("user")),
			max_width = 22,
			can_grow = false,
		},
		{
			key = "reporter",
			name = string.format("%s Reporter", icons.general("user")),
			max_width = 22,
			can_grow = false,
		},
		{ key = "status", name = " Status", can_grow = false },
	}
end

---@return table
local function compact_blank_row()
	return { icon = "", name = "", assignee = "", reporter = "", status = "" }
end

---@param issue Issue
---@return string
local function issue_meta_text(issue)
	local parts = {}
	local type_name = type(issue.type) == "table" and tostring(issue.type.name or "") or ""
	if type_name ~= "" then
		table.insert(parts, type_name)
	end
	if type(issue.priority) == "string" and issue.priority ~= "" then
		table.insert(parts, issue.priority)
	end
	local due = utils.format_date(issue.duedate)
	if due ~= "" then
		table.insert(parts, string.format("%s %s", icons.general("created"), due))
	end
	if type(issue.story_points) == "number" then
		table.insert(parts, string.format("%s pts", tostring(issue.story_points)))
	end
	if #parts == 0 then
		return tostring(issue.key or "")
	end
	return table.concat(parts, " • ")
end

---@param issues Issue[]|nil
---@return table[]
local function compact_rows(issues)
	local rows = {}
	for _, issue in ipairs(issues or {}) do
		local row = issue_to_row(issue, false)
		row.children = nil
		table.insert(rows, row)

		local meta = compact_blank_row()
		meta.kind = "meta"
		meta.name = issue_meta_text(issue)
		meta.separator = true
		meta._item = { kind = "issue_meta", key = issue.key, _issue = issue }
		table.insert(rows, meta)
	end

	return rows
end

---@param opts { width: integer }
---@param issues Issue[]|nil
---@return string[], table<integer, table>, table[]
local function render_compact_table(opts, issues)
	local rows = compact_rows(issues)
	if state.is_loading then
		table.insert(rows, compact_blank_row())
		local loading = compact_blank_row()
		loading.icon = state.reload_spinner_frame or "⠋"
		loading.name = "Loading..."
		table.insert(rows, loading)
	end

	return table_tree.render({
		width = opts.width,
		margin = 1,
		columns = compact_columns(),
		rows = rows,
		cell_hl = cell_hl,
	})
end

---@param row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
function cell_hl(row, col, ctx)
	if row.kind == "meta" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
	end

	local provider = state.provider
	if provider and provider.cell_hl then
		return provider.cell_hl(row, col, ctx)
	end
	return nil
end

---@param issue Issue
---@return string[], table[]
local function generic_issue_popup_content(issue)
	local summary = issue.summary or ""
	local title = string.format(" %s: %s", issue.key or "", summary)
	local parent_key = type(issue.parent) == "table" and issue.parent.key or nil
	local parent_summary = type(issue.parent) == "table" and issue.parent.summary or nil

	local lines = { title, "" }
	local highlights = {
		{ row = 0, col = 1, end_col = 1 + #(issue.key or ""), hl_group = helper.issue_hl(issue.key) },
		{ row = 1, col = 0, end_col = -1, hl_group = "AtlasTextMuted" },
	}
	if summary ~= "" then
		table.insert(highlights, {
			row = 0,
			col = 3 + #(issue.key or ""),
			end_col = -1,
			hl_group = helper.issue_title_hl(summary),
		})
	end

	---@param label string
	---@param value string|nil
	---@param value_hl string|nil
	local function push(label, value, value_hl)
		if value == nil or value == "" then
			return
		end
		local row = #lines
		table.insert(lines, string.format(" %-9s %s", label .. ":", value))
		table.insert(highlights, { row = row, col = 1, end_col = 10, hl_group = "AtlasTextMuted" })
		if value_hl ~= nil then
			table.insert(highlights, { row = row, col = 11, end_col = -1, hl_group = value_hl })
		end
	end

	local issue_type_name = type(issue.type) == "table" and issue.type.name or nil
	push("Type", issue_type_name, helper.issue_type_hl(issue_type_name))
	push("Status", issue.status, helper.status_hl(issue.status_id))
	push("Priority", issue.priority, helper.priority_hl(issue.priority))

	local assignee_name = type(issue.assignee) == "table" and issue.assignee.display_name or nil
	push("Assignee", assignee_name or "Unassigned", helper.person_hl(assignee_name))

	local reporter_name = type(issue.reporter) == "table" and issue.reporter.display_name or nil
	if reporter_name then
		push("Reporter", reporter_name, helper.person_hl(reporter_name))
	end

	push("Due", issue.duedate, "AtlasTextMuted")

	if type(issue.story_points) == "number" then
		push("Points", tostring(issue.story_points), "AtlasTextMuted")
	end

	if type(parent_key) == "string" and parent_key ~= "" then
		push("Parent", parent_key, helper.issue_hl(parent_key))
		if type(parent_summary) == "string" and parent_summary ~= "" then
			local row = #lines
			table.insert(lines, string.format("           %s", parent_summary))
			table.insert(highlights, { row = row, col = 11, end_col = -1, hl_group = "Comment" })
		end
	end

	local content_width = 1
	for _, line in ipairs(lines) do
		content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
	end
	lines[2] = " " .. ("━"):rep(content_width)

	return lines, highlights
end

---@param issue Issue
---@return string[], table[]
local function jira_issue_popup_content(issue)
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local fields = type(raw.fields) == "table" and raw.fields or {}
	local summary = issue.summary or ""
	local key = issue.key or ""
	local parent_key = type(issue.parent) == "table" and issue.parent.key or nil
	local parent_summary = type(issue.parent) == "table" and issue.parent.summary or nil

	local lines = { string.format(" %s: %s", key, summary), "" }
	local highlights = {
		{ row = 0, col = 1, end_col = 1 + #key, hl_group = helper.issue_hl(key) },
		{ row = 1, col = 0, end_col = -1, hl_group = "AtlasTextMuted" },
	}
	if summary ~= "" then
		table.insert(highlights, {
			row = 0,
			col = 3 + #key,
			end_col = -1,
			hl_group = helper.issue_title_hl(summary),
		})
	end

	---@param label string
	---@param value string|nil
	---@param value_hl string|nil
	local function push(label, value, value_hl)
		if value == nil or value == "" then
			return
		end
		local row = #lines
		table.insert(lines, string.format(" %-10s %s", label .. ":", value))
		table.insert(highlights, { row = row, col = 1, end_col = 11, hl_group = "AtlasTextMuted" })
		if value_hl ~= nil then
			table.insert(highlights, { row = row, col = 12, end_col = -1, hl_group = value_hl })
		end
	end

	local issue_type_name = type(issue.type) == "table" and issue.type.name or nil
	push("Type", issue_type_name, helper.issue_type_hl(issue_type_name))
	push("Status", issue.status, helper.status_hl(issue.status_id))
	push("Priority", issue.priority, helper.priority_hl(issue.priority))

	local assignee_name = type(issue.assignee) == "table" and issue.assignee.display_name or nil
	push("Assignee", assignee_name or "Unassigned", helper.person_hl(assignee_name))

	local reporter_name = type(issue.reporter) == "table" and issue.reporter.display_name or nil
	if reporter_name then
		push("Reporter", reporter_name, helper.person_hl(reporter_name))
	end

	push("Due", issue.duedate, "AtlasTextMuted")

	if type(issue.story_points) == "number" then
		push("Points", tostring(issue.story_points), "AtlasTextMuted")
	end

	---@param list any
	---@param field string|nil
	---@return string[]
	local function names(list, field)
		local out = {}
		if type(list) ~= "table" then
			return out
		end
		for _, item in ipairs(list) do
			if field == nil then
				if type(item) == "string" and item ~= "" then
					table.insert(out, item)
				end
			elseif type(item) == "table" then
				local v = item[field]
				if type(v) == "string" and v ~= "" then
					table.insert(out, v)
				end
			end
		end
		return out
	end

	local labels = names(fields.labels)
	if #labels > 0 then
		push("Labels", table.concat(labels, ", "), "AtlasTextMuted")
	end

	local components = names(fields.components, "name")
	if #components > 0 then
		push("Components", table.concat(components, ", "), "AtlasTextMuted")
	end

	local fix_versions = names(fields.fixVersions, "name")
	if #fix_versions > 0 then
		push("Fix In", table.concat(fix_versions, ", "), "AtlasTextMuted")
	end

	local resolution = type(fields.resolution) == "table" and fields.resolution.name or nil
	if type(resolution) == "string" then
		push("Resolved", resolution, "AtlasTextMuted")
	end

	push("Updated", utils.relative_time(fields.updated), "AtlasTextMuted")

	if type(parent_key) == "string" and parent_key ~= "" then
		push("Parent", parent_key, helper.issue_hl(parent_key))
		if type(parent_summary) == "string" and parent_summary ~= "" then
			local row = #lines
			table.insert(lines, string.format("            %s", parent_summary))
			table.insert(highlights, { row = row, col = 12, end_col = -1, hl_group = "Comment" })
		end
	end

	local content_width = 1
	for _, line in ipairs(lines) do
		content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
	end
	lines[2] = " " .. ("━"):rep(content_width)

	return lines, highlights
end

---@param issue Issue
---@return string[], table[]
local function github_issue_popup_content(issue)
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local summary = issue.summary or ""
	local key = issue.key or ""

	local lines = { string.format(" %s: %s", key, summary), "" }
	local highlights = {
		{ row = 0, col = 1, end_col = 1 + #key, hl_group = helper.issue_hl(key) },
		{ row = 1, col = 0, end_col = -1, hl_group = "AtlasTextMuted" },
	}
	if summary ~= "" then
		table.insert(highlights, {
			row = 0,
			col = 3 + #key,
			end_col = -1,
			hl_group = helper.issue_title_hl(summary),
		})
	end

	---@param label string
	---@param value string|nil
	---@param value_hl string|nil
	local function push(label, value, value_hl)
		if value == nil or value == "" then
			return
		end
		local row = #lines
		table.insert(lines, string.format(" %-10s %s", label .. ":", value))
		table.insert(highlights, { row = row, col = 1, end_col = 11, hl_group = "AtlasTextMuted" })
		if value_hl ~= nil then
			table.insert(highlights, { row = row, col = 12, end_col = -1, hl_group = value_hl })
		end
	end

	push("Status", issue.status, helper.status_hl(issue.status_id))

	local reporter_name = type(issue.reporter) == "table" and issue.reporter.display_name or nil
	push("Author", reporter_name, helper.person_hl(reporter_name))

	local assignees = type(raw.assignees) == "table" and raw.assignees or {}
	if #assignees > 0 then
		local logins = {}
		for _, a in ipairs(assignees) do
			table.insert(logins, "@" .. tostring(a.login or ""))
		end
		push("Assignees", table.concat(logins, ", "), "AtlasTextMuted")
	end

	local labels = type(raw.labels) == "table" and raw.labels or {}
	if #labels > 0 then
		local names = {}
		for _, l in ipairs(labels) do
			table.insert(names, tostring(l.name or ""))
		end
		push("Labels", table.concat(names, ", "), "AtlasTextMuted")
	end

	local milestone = raw.milestone
	if type(milestone) == "table" and milestone.title then
		push("Milestone", tostring(milestone.title), "AtlasTextMuted")
	end

	push("Comments", tostring(tonumber(raw.comment_count) or 0), "AtlasTextMuted")
	push("Updated", utils.relative_time(raw.updated_at), "AtlasTextMuted")

	local content_width = 1
	for _, line in ipairs(lines) do
		content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
	end
	lines[2] = " " .. ("━"):rep(content_width)

	return lines, highlights
end

---@param issue Issue
---@return string[], table[]
function M.issue_popup_content(issue)
	local provider_id = state.provider and state.provider.id or ""
	if provider_id == "jira" then
		return jira_issue_popup_content(issue)
	end
	if provider_id == "github" then
		return github_issue_popup_content(issue)
	end
	return generic_issue_popup_content(issue)
end

---@param opts { width: integer, height: integer }
---@return string[], table[], table<integer, table>
function M.render(opts)
	local provider = state.provider
	local provider_icon = provider and provider.icon or "•"
	local provider_name = provider and provider.name or "Issues"
	local provider_hl = provider and provider.hl_group or "Title"

	local views = provider and provider.views and provider.views() or {}
	local active = state.active_view
	local active_id = view_id(active)

	local nav_items = {}
	local active_is_listed = false
	for _, v in ipairs(views) do
		local id = view_id(v)
		local label = v.key and string.format("%s (%s)", v.name, v.key) or v.name
		if id == active_id then
			active_is_listed = true
		end
		table.insert(nav_items, {
			label = label,
			active = id == active_id,
		})
	end

	if not active_is_listed and type(active) == "table" then
		table.insert(nav_items, {
			label = tostring(active.name or "-"),
			active = true,
		})
	end

	local actions = {}

	if state.provider and state.provider.fetch_notifications then
		local notif_state = require("atlas.ui.notifications.state")
		local count = notif_state.unread_count or 0
		local bell_icon = count > 0 and icons.general("bell_unread") or icons.general("bell")
		local bell_label = count > 0 and string.format("%s %d", bell_icon, count) or bell_icon
		local bell_hl = count > 0 and "AtlasLogInfo" or "AtlasTextMuted"
		table.insert(actions, { label = bell_label, hl_group = bell_hl })
		table.insert(actions, { label = "|", hl_group = "AtlasTextMuted" })
	end

	table.insert(actions, {
		label = string.format("Refresh (%s)", key_label("ui.refresh_view", "R")),
		hl_group = "AtlasTextMuted",
	})

	local lines, spans = {}, {}
	local line_map = {}

	utils.append_block(
		lines,
		spans,
		header.render({
			width = opts.width,
			icon = provider_icon,
			title = provider_name,
			hl_group = provider_hl,
		})
	)

	utils.append_block(
		lines,
		spans,
		navbar.render({
			width = opts.width,
			items = nav_items,
			actions = actions,
			active_hl = provider_hl,
		})
	)

	table.insert(lines, "")

	if state.error then
		local err_text = "Error: " .. state.error
		utils.append_block(lines, spans, {
			lines = { err_text },
			highlights = {
				{ line = 0, start_col = 0, end_col = #err_text, hl_group = "AtlasLogError" },
			},
		})
	else
		local issue_groups = state.issue_tree or {}
		local layout = type(active) == "table" and tostring(active.layout or "plain") or "plain"
		if layout ~= "compact" then
			layout = "plain"
		end
		local issues = state.issues or {}
		append_search_text(lines, spans, search_text(active))

		local has_rows = #issue_groups > 0
		if layout == "compact" then
			has_rows = #issues > 0
		end
		if state.is_loading ~= true and not has_rows then
			table.insert(lines, "No issues found.")
		else
			local tbl_lines, tbl_spans, tbl_map
			if provider and provider.render then
				local result = provider.render(issue_groups, layout, { width = opts.width })
				tbl_lines = result.lines or {}
				tbl_spans = result.spans or {}
				tbl_map = result.line_map or {}
			elseif layout == "compact" then
				tbl_lines, tbl_map, tbl_spans = render_compact_table(opts, issues)
			else
				tbl_lines, tbl_map, tbl_spans = render_issue_table(opts, issue_groups)
			end

			local table_base = #lines
			utils.append_block(lines, spans, { lines = tbl_lines, highlights = tbl_spans })

			for lnum, node in pairs(tbl_map) do
				line_map[table_base + lnum] = node
			end

			local issue_count = #(state.issues or {})
			local user_name = (state.current_user and state.current_user.display_name) or ""
			local footer_items = {
				{ text = string.format("%d issues", issue_count), hl_group = provider_hl },
			}
			if user_name ~= "" then
				table.insert(footer_items, { text = "|", hl_group = "AtlasFooterText" })
				table.insert(footer_items, { text = "@" .. user_name, hl_group = "AtlasFooterText" })
			end
			footer.set_items(footer_items)
		end
	end

	return lines, spans, line_map
end

return M
