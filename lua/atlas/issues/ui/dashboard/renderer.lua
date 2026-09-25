local resolver = require("atlas.core.keymaps")
local state = require("atlas.issues.state")
local header = require("atlas.ui.components.header")
local navbar = require("atlas.ui.components.navbar")
local utils = require("atlas.ui.shared.utils")
local statusline = require("atlas.ui.statusline")
local icons = require("atlas.ui.shared.icons")
local bookmarks = require("atlas.ui.shared.bookmarks")
local issue_list = require("atlas.issues.ui.components.issue_list")
local notif_state = require("atlas.ui.notifications.state")

local M = {}

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

---@param opts { width: integer }
---@return string[], table[], table<integer, table>
function M.render(opts)
	local provider = state.provider
	local provider_icon = provider and provider.icon or icons.fallback()
	local provider_name = provider and provider.name or "Issues"
	local provider_hl = provider and provider.hl_group or "Title"
	local issue_count = #state.issues
	local statusline_items = {
		{ text = string.format("%d issues", issue_count), hl_group = "AtlasFooterText" },
	}
	local page = state.page_history[state.current_page]
	if page == nil and state.is_loading then
		page = state.page_history[state.current_page - 1]
	end
	if page ~= nil and (state.current_page > 1 or page.next_cursor ~= nil) then
		local page_number = tostring(state.current_page)
		if page.total_pages ~= nil then
			page_number = page_number .. "/" .. page.total_pages
		end
		statusline_items[#statusline_items + 1] = { text = "Page", hl_group = "AtlasFooterText" }
		statusline_items[#statusline_items + 1] = {
			text = page_number,
			hl_group = "AtlasFooterActive",
		}
	end
	local user_name = (state.current_user and state.current_user.name) or ""
	if user_name ~= "" then
		statusline_items[#statusline_items + 1] = {
			text = "| @" .. user_name,
			hl_group = "AtlasFooterText",
			priority = 50,
			min_width = 8,
		}
	end
	statusline.set_items(statusline_items)

	local views = state.views
	local view = state.view
	local active_id = view_id(view)

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

	if not active_is_listed and view ~= nil then
		table.insert(nav_items, {
			label = tostring(view.name or "-"),
			active = true,
		})
	end

	local actions = {}

	if provider and provider.capabilities.notifications then
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

	local bookmark_state = state.bookmarks
	if bookmark_state ~= nil and view == bookmark_state.tab then
		bookmarks.render(lines, spans, line_map, opts.width, bookmark_state, state.starred_items)
		if bookmark_state.selection == nil then
			return lines, spans, line_map
		end
		table.insert(lines, "")
	end

	local search_view = state.search_view()
	if state.error then
		if search_view ~= nil then
			append_search_text(lines, spans, state.query)
		end
		local err_text = "Error: " .. state.error
		utils.append_block(lines, spans, {
			lines = { err_text },
			highlights = {
				{ line = 0, start_col = 0, end_col = #err_text, hl_group = "AtlasLogError" },
			},
		})
	else
		local issue_groups = state.issue_tree
		local layout = search_view and tostring(search_view.layout or "plain") or "compact"
		if layout ~= "compact" then
			layout = "plain"
		end
		local issues = state.issues
		if search_view ~= nil then
			append_search_text(lines, spans, state.query)
		end

		local has_rows = #issue_groups > 0
		if layout == "compact" then
			has_rows = #issues > 0
		end
		if state.is_loading ~= true and not has_rows then
			table.insert(lines, "No issues found.")
		else
			local list_opts = {
				width = opts.width,
				provider_id = provider and provider.id,
				loading = state.is_loading,
				reloading = state.reloading_issue_keys,
				spinner = state.reload_spinner_frame,
				collapsed = state.collapsed_issue_keys,
			}
			local tbl_lines, tbl_spans, tbl_map
			if layout == "compact" then
				tbl_lines, tbl_map, tbl_spans = issue_list.render_compact(list_opts, issues)
			else
				tbl_lines, tbl_map, tbl_spans = issue_list.render_plain(list_opts, issue_groups)
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
