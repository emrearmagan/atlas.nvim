local M = {}

local state = require("atlas.pulls.state")
local helper = require("atlas.pulls.ui.dashboard.helper")
local header = require("atlas.ui.components.header")
local icons = require("atlas.ui.shared.icons")
local navbar = require("atlas.ui.components.navbar")
local table_tree = require("atlas.ui.components.table_tree")
local ui_utils = require("atlas.ui.utils")
local utils = require("atlas.ui.shared.utils")
local statusline = require("atlas.ui.statusline")

---@param lines string[]
---@param text string
---@param width integer
---@param height integer
local function append_centered_loading(lines, text, width, height)
	local available_height = math.max(1, height - #lines)
	for _ = 1, math.max(0, math.floor((available_height - 1) / 2)) do
		table.insert(lines, "")
	end
	local centered = ui_utils.center_text(text, width)
	table.insert(lines, centered)
end

---@param lines string[]
---@param spans table[]
local function append_search_text(lines, spans)
	local view = state.active_view
	if type(view) == "table" and view._kind == "bookmarks" then
		view = state.current_view
	end
	if type(view) ~= "table" or view._kind ~= nil or state.provider == nil then
		return
	end

	local text = state.provider.capabilities.core.search_query(view, {})
	if text == "" then
		return
	end
	local line = string.format(" %s %s", icons.general("search"), text)
	table.insert(lines, line)
	table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #line, hl_group = "AtlasTextMuted" })
	table.insert(lines, "")
end

---@param table_lines string[]
---@param table_map table<integer, table>
---@param table_spans table[]
local function add_pr_reference_spans(table_lines, table_map, table_spans)
	for lnum, item in pairs(table_map or {}) do
		if item.kind == "pr" then
			local line = table_lines[lnum] or ""
			local reference = "#" .. tostring(item.pr.id)
			local s, e = string.find(line, reference, 1, true)
			if s and e then
				table.insert(table_spans, {
					line = lnum - 1,
					start_col = s - 1,
					end_col = e,
					hl_group = "AtlasTextMuted",
				})
			end
		end
	end
end

---@param opts { width: integer }
---@param pulls PullRequest[]
---@return string[], table[], table<integer, table>
local function build_compact_content(opts, pulls)
	local table_data = helper.build_compact_table(pulls)
	local tbl_lines, tbl_map, tbl_spans = table_tree.render({
		width = opts.width,
		margin = 1,
		columns = table_data.columns,
		rows = table_data.rows,
		cell_hl = helper.cell_hl,
	})
	add_pr_reference_spans(tbl_lines, tbl_map, tbl_spans)
	return tbl_lines, tbl_spans, tbl_map
end

---@param opts { width: integer }
---@param pulls PullRequest[]
---@param layout "grouped"|"plain"
---@return string[], table[], table<integer, table>
local function build_list_content(opts, pulls, layout)
	local table_data = helper.build_list_table(pulls, layout)
	local tbl_lines, tbl_map, tbl_spans = table_tree.render({
		width = opts.width,
		margin = 1,
		columns = table_data.columns,
		rows = table_data.rows,
		cell_hl = helper.cell_hl,
	})
	add_pr_reference_spans(tbl_lines, tbl_map, tbl_spans)
	return tbl_lines, tbl_spans, tbl_map
end

---@param lines string[]
---@param spans table[]
---@param width integer
local function render_header(lines, spans, width)
	---@param v AtlasPullsViewConfig|nil
	---@return string
	local function view_id_str(v)
		if v == nil then
			return ""
		end
		return tostring(v.key or v.name or "")
	end

	local icon = state.provider and state.provider.icon or icons.fallback()
	local title = state.provider and state.provider.name or "Atlas"
	local hl_group = state.provider and state.provider.hl_group or "Title"

	utils.append_block(
		lines,
		spans,
		header.render({
			width = width,
			icon = icon,
			title = title,
			hl_group = hl_group,
		})
	)

	local views = state.provider and require("atlas.ui.shared.bookmarks_view").views(state.provider, "pulls") or {}
	local nav_source = {}
	for _, v in ipairs(views or {}) do
		table.insert(nav_source, v)
	end

	local active = state.active_view
	local active_id = view_id_str(active)
	local exists = false
	for _, v in ipairs(nav_source) do
		if view_id_str(v) == active_id then
			exists = true
			break
		end
	end
	if active ~= nil and active_id ~= "" and not exists then
		table.insert(nav_source, active)
	end

	local nav_items = {}
	for _, v in ipairs(nav_source) do
		local label = v.key and string.format("%s (%s)", v.name, v.key) or v.name
		table.insert(nav_items, {
			label = label,
			active = view_id_str(v) == active_id,
		})
	end

	local actions = {}

	local STATUS_ORDER = { "OPEN", "MERGED", "DECLINED" }
	for _, s in ipairs(STATUS_ORDER) do
		local label = s:sub(1, 1):upper() .. s:sub(2):lower()
		local hl = state.status_filters[s] and "AtlasLogInfo" or "AtlasTextMuted"
		table.insert(actions, { label = label, hl_group = hl })
	end

	if state.provider and state.provider.capabilities.notifications then
		table.insert(actions, { label = "|", hl_group = "AtlasTextMuted" })
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
	end

	utils.append_block(
		lines,
		spans,
		navbar.render({
			width = width,
			items = nav_items,
			actions = actions,
			active_hl = state.provider and state.provider.hl_group or "Title",
		})
	)
end

---@param opts { width: integer, height: integer }
---@return string[] lines, table[] spans, table<integer, table> line_map
function M.render(opts)
	local lines, spans = {}, {}
	local line_map = {}
	local pulls = helper.starred_first(state.pulls or {})
	local loading_text = string.format("%s Loading...", state.reload_spinner_frame or "⠋")
	statusline.set_items(helper.build_statusline_items(pulls, state.current_user))

	table.insert(lines, "")
	render_header(lines, spans, opts.width)
	table.insert(lines, "")

	local active = state.active_view
	if type(active) == "table" and active._kind == "bookmarks" then
		append_search_text(lines, spans)
		require("atlas.ui.shared.bookmarks_view").render(
			lines,
			spans,
			line_map,
			active._bookmarks or {},
			opts.width,
			active._starred
		)

		if state.error then
			local error_text = tostring(state.error or ""):gsub("[\r\n]+", " | ")
			local err_line = "Error: " .. error_text
			table.insert(lines, "")
			utils.append_block(lines, spans, {
				lines = { err_line },
				highlights = {
					{ line = 0, start_col = 0, end_col = #err_line, hl_group = "AtlasLogError" },
				},
			})
		elseif state.is_loading then
			table.insert(lines, "")
			append_centered_loading(lines, loading_text, opts.width, opts.height)
		elseif #pulls > 0 then
			table.insert(lines, "")
			local body_lines, body_spans, body_map
			local ui = state.provider and state.provider.capabilities.ui
			if ui and ui.render then
				local result = ui.render(pulls, "grouped", { width = opts.width })
				body_lines, body_spans, body_map = result.lines, result.spans, result.line_map
			else
				body_lines, body_spans, body_map = build_list_content(opts, pulls, "grouped")
			end
			local body_base = #lines
			utils.append_block(lines, spans, { lines = body_lines, highlights = body_spans })
			for lnum, node in pairs(body_map) do
				line_map[body_base + lnum] = node
			end
		end

		return lines, spans, line_map
	end

	append_search_text(lines, spans)

	if state.error then
		local error_text = tostring(state.error or ""):gsub("[\r\n]+", " | ")
		local err_line = "Error: " .. error_text
		utils.append_block(lines, spans, {
			lines = { err_line },
			highlights = {
				{ line = 0, start_col = 0, end_col = #err_line, hl_group = "AtlasLogError" },
			},
		})
	elseif state.is_loading then
		append_centered_loading(lines, loading_text, opts.width, opts.height)
	else
		local layout = state.active_view and state.active_view.layout or "compact"
		local body_lines, body_spans, body_map

		local ui = state.provider and state.provider.capabilities.ui
		if ui and ui.render then
			local result = ui.render(pulls, layout, { width = opts.width })
			body_lines, body_spans, body_map = result.lines, result.spans, result.line_map
		elseif layout == "grouped" or layout == "plain" then
			body_lines, body_spans, body_map = build_list_content(opts, pulls, layout)
		else
			body_lines, body_spans, body_map = build_compact_content(opts, pulls)
		end

		local body_base = #lines
		utils.append_block(lines, spans, { lines = body_lines, highlights = body_spans })
		for lnum, node in pairs(body_map) do
			line_map[body_base + lnum] = node
		end
	end

	return lines, spans, line_map
end

return M
