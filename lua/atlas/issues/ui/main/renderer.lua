local M = {}

local resolver = require("atlas.core.keymaps")
local state = require("atlas.issues.state")
local header = require("atlas.ui.components.header")
local navbar = require("atlas.ui.components.navbar")
local table_tree = require("atlas.ui.components.table_tree")
local utils = require("atlas.ui.shared.utils")
local statusline = require("atlas.ui.statusline")
local icons = require("atlas.ui.shared.icons")
local STAR_ICON, STAR_ICON_HL = icons.general("star")

---@param view IssuesViewConfig|nil
---@return string
local function view_id(view)
	if view == nil then
		return ""
	end
	return view.key or view.name or ""
end

---@param action_id AtlasKeymapActionId|string
---@return string|nil
local function key_label(action_id)
	local keys = resolver.resolve(action_id)
	return keys and keys[1] or nil
end

---@param view IssuesViewConfig|nil
---@return string
local function search_text(view)
	if type(view) ~= "table" then
		return ""
	end

	local provider_id = state.provider and state.provider.id or ""
	if provider_id == "gitea" or provider_id == "forgejo" then
		if view._kind == "bookmarks" or view._kind == "starred" then
			return ""
		end
		local repo = vim.trim(view.repo or "")
		local parts = { repo ~= "" and ("repo:" .. repo) or "type:issues", "is:" .. (view.state or "open") }
		local scope = view.scope or ""
		if scope ~= "" and scope ~= "all" then
			table.insert(parts, "scope:" .. scope)
		end
		local labels = vim.trim(view.labels or "")
		if labels ~= "" then
			table.insert(parts, "labels:" .. labels)
		end
		local extra_keys = vim.tbl_keys(view.extra_params or {})
		table.sort(extra_keys)
		for _, key in ipairs(extra_keys) do
			table.insert(parts, key .. ":" .. tostring(view.extra_params[key]))
		end
		local search = vim.trim(view.search or "")
		if search ~= "" then
			table.insert(parts, search)
		end
		return table.concat(parts, " ")
	end
	if provider_id == "github" then
		local search = tostring(view.search or "")
		if search ~= "" and not search:lower():find("is:issue", 1, true) then
			search = search .. " is:issue"
		end
		return search
	end

	local jira_view = view
	---@cast jira_view AtlasJiraViewConfig
	local jql = tostring(jira_view.jql or "")
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
	local ui = provider and provider.capabilities.ui
	if ui and ui.format_row then
		row_data = ui.format_row(issue, is_child == true)
	end
	if row_data == nil then
		row_data = {
			icon = "",
			name = (issue.key or "") .. " " .. (issue.title or ""),
			assignee = (issue.assignee and issue.assignee.display_name) or "Unassigned",
			reporter = (issue.reporter and issue.reporter.display_name) or "Unknown",
			status = string.format(" %s ", issue.status or ""),
		}
	end

	if issue.is_starred then
		row_data.name = STAR_ICON .. " " .. row_data.name
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
		if #(group.children or {}) > 0 then
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
				local issue = row._issue
				local issue_key = issue and tostring(issue.key or "") or ""
				if issue_key == "" then
					return true
				end
				return (state.collapsed_issue_keys or {})[issue_key] ~= true
			end,
		},
		cell_hl = cell_hl,
	})
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
	local type_name = issue.type and tostring(issue.type.name or "") or ""
	if type_name ~= "" then
		table.insert(parts, type_name)
	end
	if issue.priority and issue.priority ~= "" then
		table.insert(parts, issue.priority)
	end
	local due = utils.format_date(issue.duedate)
	if due ~= "" then
		table.insert(parts, string.format("%s %s", icons.general("created"), due))
	end
	if issue.story_points ~= nil then
		table.insert(parts, string.format("%s pts", tostring(issue.story_points)))
	end
	if #parts == 0 then
		return tostring(issue.key or "")
	end
	return table.concat(parts, "  ")
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
	local ui = provider and provider.capabilities.ui
	local spans
	if ui and ui.cell_hl then
		spans = ui.cell_hl(row, col, ctx)
	end
	if col.key == "name" and row._issue and row._issue.is_starred then
		spans = spans or {}
		table.insert(spans, 1, { start_col = 0, end_col = #STAR_ICON, hl_group = STAR_ICON_HL })
	end
	return spans
end

---@param opts { width: integer, height: integer }
---@return string[], table[], table<integer, table>
function M.render(opts)
	local provider = state.provider
	local provider_icon = provider and provider.icon or icons.fallback()
	local provider_name = provider and provider.name or "Issues"
	local provider_hl = provider and provider.hl_group or "Title"
	local issue_count = #(state.issues or {})
	local statusline_items = {
		{ text = string.format("%d issues", issue_count), hl_group = "AtlasFooterText" },
	}
	local user_name = (state.current_user and state.current_user.display_name) or ""
	if user_name ~= "" then
		statusline_items[#statusline_items + 1] = {
			text = "| @" .. user_name,
			hl_group = "AtlasFooterText",
			priority = 50,
			min_width = 8,
		}
	end
	statusline.set_items(statusline_items)

	local views = provider and require("atlas.ui.shared.bookmarks_view").views(provider, "issues") or {}
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

	if provider and provider.capabilities.notifications then
		local notif_state = require("atlas.ui.notifications.state")
		local count = notif_state.unread_count or 0
		local bell_icon, bell_hl
		if count > 0 then
			bell_icon, bell_hl = icons.general("bell_unread")
		else
			bell_icon, bell_hl = icons.general("bell")
		end
		local bell_label = count > 0 and string.format("%s %d", bell_icon, count) or bell_icon
		table.insert(actions, { label = bell_label, hl_group = bell_hl })
		table.insert(actions, { label = "|", hl_group = "AtlasTextMuted" })
	end

	local refresh_key = key_label("ui.refresh_view")
	if refresh_key then
		table.insert(actions, {
			label = string.format("Refresh (%s)", refresh_key),
			hl_group = "AtlasTextMuted",
		})
	end

	local lines, spans = {}, {}
	local line_map = {}

	table.insert(lines, "")
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

	if type(active) == "table" and active._kind == "bookmarks" then
		append_search_text(lines, spans, search_text(state.current_view))
		require("atlas.ui.shared.bookmarks_view").render(
			lines,
			spans,
			line_map,
			active._bookmarks or {},
			opts.width,
			active._starred
		)

		local issues = state.issues or {}
		local issue_groups = state.issue_tree or {}
		if state.error then
			local err_text = "Error: " .. state.error
			table.insert(lines, "")
			utils.append_block(lines, spans, {
				lines = { err_text },
				highlights = {
					{ line = 0, start_col = 0, end_col = #err_text, hl_group = "AtlasLogError" },
				},
			})
		elseif state.is_loading then
			table.insert(lines, "")
			table.insert(lines, "Loading...")
		elseif #issues > 0 or #issue_groups > 0 then
			table.insert(lines, "")
			local tbl_lines, tbl_spans, tbl_map
			local ui = provider and provider.capabilities.ui
			if ui and ui.render then
				local result = ui.render(issue_groups, "plain", { width = opts.width })
				tbl_lines = result.lines or {}
				tbl_spans = result.spans or {}
				tbl_map = result.line_map or {}
			else
				tbl_lines, tbl_map, tbl_spans = render_issue_table(opts, issue_groups)
			end
			local table_base = #lines
			utils.append_block(lines, spans, { lines = tbl_lines, highlights = tbl_spans })
			for lnum, node in pairs(tbl_map) do
				line_map[table_base + lnum] = node
			end
		end
	elseif state.error then
		append_search_text(lines, spans, search_text(active))
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
			local ui = provider and provider.capabilities.ui
			if ui and ui.render then
				local result = ui.render(issue_groups, layout, { width = opts.width })
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
		end
	end

	return lines, spans, line_map
end

return M
