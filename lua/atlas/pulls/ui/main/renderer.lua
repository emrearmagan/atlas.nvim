local M = {}

local resolver = require("atlas.core.keymaps")
local state = require("atlas.pulls.state")
local helper = require("atlas.pulls.ui.main.helper")
local header = require("atlas.ui.components.header")
local icons = require("atlas.ui.shared.icons")
local navbar = require("atlas.ui.components.navbar")
local table_tree = require("atlas.ui.components.table_tree")
local utils = require("atlas.ui.shared.utils")
local footer = require("atlas.ui.components.footer")

---@param lines string[]
---@param spans table[]
local function append_search_text(lines, spans)
	local text = tostring(state.last_search_query or "")
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
local function add_pr_id_spans(table_lines, table_map, table_spans)
	for lnum, item in pairs(table_map or {}) do
		if type(item) == "table" and item.kind == "pr" then
			local line = table_lines[lnum] or ""
			local s, e = string.find(line, "#%d+")
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

---@return string
local function refresh_key_display()
	local keys = resolver.resolve("ui.refresh_view")
	if type(keys) == "table" and #keys > 0 then
		return tostring(keys[1])
	end
	return "R"
end

---@param opts { width: integer }
---@param repos PullsGroup[]
---@return string[], table[], table<integer, table>
local function build_plain_content(opts, repos)
	local table_data = helper.build_compact_table(repos)
	local tbl_lines, tbl_map, tbl_spans = table_tree.render({
		width = opts.width,
		margin = 1,
		columns = table_data.columns,
		rows = table_data.rows,
		cell_hl = helper.cell_hl,
	})
	add_pr_id_spans(tbl_lines, tbl_map, tbl_spans)
	return tbl_lines, tbl_spans, tbl_map
end

---@param opts { width: integer }
---@param repos PullsGroup[]
---@return string[], table[], table<integer, table>
local function build_plain_singleline_content(opts, repos)
	local table_data = helper.build_plain_tree_table(repos)
	local tbl_lines, tbl_map, tbl_spans = table_tree.render({
		width = opts.width,
		margin = 1,
		columns = table_data.columns,
		rows = table_data.rows,
		cell_hl = helper.cell_hl,
	})
	add_pr_id_spans(tbl_lines, tbl_map, tbl_spans)
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

	local icon = state.provider and state.provider.icon or "•"
	local title = state.provider and state.provider.name or "Atlas"
	local hl_group = state.provider and state.provider.hl_group or "Title"

	utils.append_block(lines, spans, header.render({
		width = width,
		icon = icon,
		title = title,
		hl_group = hl_group,
	}))

	local views = state.provider and state.provider.views and state.provider.views() or {}
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

	table.insert(actions, { label = "|", hl_group = "AtlasTextMuted" })

	if state.provider and state.provider.fetch_notifications then
		local notif_state = require("atlas.ui.notifications.state")
		local icons_mod = require("atlas.ui.shared.icons")
		local count = notif_state.unread_count or 0
		local bell_icon = count > 0 and icons_mod.general("bell_unread") or icons_mod.general("bell")
		local bell_label = count > 0 and string.format("%s %d", bell_icon, count) or bell_icon
		local bell_hl = count > 0 and "AtlasLogInfo" or "AtlasTextMuted"
		table.insert(actions, { label = bell_label, hl_group = bell_hl })
		table.insert(actions, { label = "|", hl_group = "AtlasTextMuted" })
	end

	table.insert(actions, {
		label = string.format("Refresh (%s)", refresh_key_display()),
		hl_group = "AtlasTextMuted",
	})

	utils.append_block(lines, spans, navbar.render({
		width = width,
		items = nav_items,
		actions = actions,
		active_hl = state.provider and state.provider.hl_group or "Title",
	}))
end

---@param opts { width: integer, height: integer }
---@return string[] lines, table[] spans, table<integer, table> line_map
function M.render(opts)
	local lines, spans = {}, {}
	local line_map = {}

	render_header(lines, spans, opts.width)
	table.insert(lines, "")

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
		table.insert(lines, "Loading...")
	else
		local layout = state.active_view and state.active_view.layout or "compact"
		local groups = state.pulls or {}
		local body_lines, body_spans, body_map

		if state.provider and state.provider.render then
			local result = state.provider.render(groups, layout, { width = opts.width })
			body_lines, body_spans, body_map = result.lines, result.spans, result.line_map
		elseif layout == "plain" then
			body_lines, body_spans, body_map = build_plain_singleline_content(opts, groups)
		else
			body_lines, body_spans, body_map = build_plain_content(opts, groups)
		end

		local body_base = #lines
		utils.append_block(lines, spans, { lines = body_lines, highlights = body_spans })
		for lnum, node in pairs(body_map) do
			line_map[body_base + lnum] = node
		end

		footer.set_items(helper.build_footer_items(groups, state.current_user))
	end

	return lines, spans, line_map
end

return M
