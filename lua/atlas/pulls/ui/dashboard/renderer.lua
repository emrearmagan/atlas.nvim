local header = require("atlas.ui.components.header")
local icons = require("atlas.ui.shared.icons")
local navbar = require("atlas.ui.components.navbar")
local notif_state = require("atlas.ui.notifications.state")
local pull_list = require("atlas.pulls.ui.components.pull_list")
local state = require("atlas.pulls.state")
local statusline = require("atlas.ui.statusline")
local bookmarks = require("atlas.ui.shared.bookmarks")
local ui_utils = require("atlas.ui.utils")
local utils = require("atlas.ui.shared.utils")

local M = {}

local PR_ICON = icons.pulls("pr")

---@param pulls PullRequest[]
---@return table[]
local function statusline_items(pulls)
	local items = {
		{
			text = string.format("%s %d PR%s", PR_ICON, #pulls, #pulls == 1 and "" or "s"),
			hl_group = "AtlasFooterInfo",
		},
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
		table.insert(items, {
			text = "Page",
			hl_group = "AtlasFooterText",
		})
		table.insert(items, {
			text = page_number,
			hl_group = "AtlasFooterActive",
		})
	end
	local user = state.current_user
	if user ~= nil then
		local user_name = tostring(user.username or user.name or "")
		if user_name ~= "" then
			table.insert(items, {
				text = string.format("%s @%s", icons.general("user"), user_name),
				hl_group = "AtlasFooterText",
				priority = 50,
				min_width = 8,
			})
		end
	end
	return items
end

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
	local view = state.search_view()
	if view == nil then
		return
	end
	local text = state.query
	if text == "" then
		return
	end
	local line = string.format(" %s %s", icons.general("search"), text)
	table.insert(lines, line)
	table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #line, hl_group = "AtlasTextMuted" })
	table.insert(lines, "")
end

---@param lines string[]
---@param spans table[]
---@param width integer
local function render_header(lines, spans, width)
	local function view_id(view)
		return view and tostring(view.key or view.name or "") or ""
	end
	local icon = state.provider and state.provider.icon or icons.fallback()
	local title = state.provider and state.provider.name or "Atlas"
	local hl = state.provider and state.provider.hl_group or "Title"
	utils.append_block(lines, spans, header.render({ width = width, icon = icon, title = title, hl_group = hl }))

	local views = vim.list_extend({}, state.views)
	local active_view = state.view
	local active_id = view_id(active_view)
	local found = false
	for _, view in ipairs(views) do
		if view_id(view) == active_id then
			found = true
			break
		end
	end
	if active_view ~= nil and active_id ~= "" and not found then
		table.insert(views, active_view)
	end
	local nav_items = {}
	for _, view in ipairs(views) do
		table.insert(nav_items, {
			label = view.key and string.format("%s (%s)", view.name, view.key) or view.name,
			active = view_id(view) == active_id,
		})
	end

	local actions = {}
	if state.search_view() then
		local selected = {}
		for _, value in ipairs(state.selected_states()) do
			selected[value] = true
		end
		for _, status in ipairs(state.available_states) do
			local label = status:sub(1, 1):upper() .. status:sub(2):lower()
			table.insert(actions, {
				label = label,
				hl_group = selected[status] and "AtlasLogInfo" or "AtlasTextMuted",
			})
		end
	end
	if state.provider and state.provider.capabilities.notifications then
		if #actions > 0 then
			table.insert(actions, { label = "|", hl_group = "AtlasTextMuted" })
		end
		local count = notif_state.unread_count or 0
		local bell, bell_hl = icons.general(count > 0 and "bell_unread" or "bell")
		table.insert(actions, {
			label = count > 0 and string.format("%s %d", bell, count) or bell,
			hl_group = bell_hl,
		})
	end
	utils.append_block(
		lines,
		spans,
		navbar.render({
			width = width,
			items = nav_items,
			actions = actions,
			active_hl = hl,
		})
	)
end

---@param opts { width: integer, height: integer }
---@return string[], table[], table<integer, table>
function M.render(opts)
	local lines, spans, line_map = {}, {}, {}
	local pulls = state.pulls
	local loading = string.format("%s Loading...", state.reload_spinner_frame)
	statusline.set_items(statusline_items(pulls))

	table.insert(lines, "")
	render_header(lines, spans, opts.width)
	table.insert(lines, "")

	local view = state.view
	local bookmark_state = state.bookmarks
	if bookmark_state ~= nil and view == bookmark_state.tab then
		bookmarks.render(lines, spans, line_map, opts.width, bookmark_state, state.starred_items)
		if bookmark_state.selection == nil then
			return lines, spans, line_map
		end
		table.insert(lines, "")
	end

	append_search_text(lines, spans)
	if state.error then
		local text = "Error: " .. tostring(state.error):gsub("[\r\n]+", " | ")
		utils.append_block(lines, spans, {
			lines = { text },
			highlights = { { line = 0, start_col = 0, end_col = #text, hl_group = "AtlasLogError" } },
		})
	elseif state.is_loading then
		append_centered_loading(lines, loading, opts.width, opts.height)
	else
		local search_view = state.search_view()
		local layout = search_view and search_view.layout or "compact"
		local body_lines, body_map, body_spans = pull_list.render({
			width = opts.width,
			provider_id = state.provider and state.provider.id,
			layout = layout,
			reloading = state.reloading_pr_keys,
			spinner = state.reload_spinner_frame,
		}, pulls)
		local base = #lines
		utils.append_block(lines, spans, { lines = body_lines, highlights = body_spans })
		for lnum, item in pairs(body_map) do
			line_map[base + lnum] = item
		end
	end
	return lines, spans, line_map
end

return M
