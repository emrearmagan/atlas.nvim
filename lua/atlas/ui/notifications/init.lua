local M = {}

local footer = require("atlas.ui.components.footer")
local icons = require("atlas.ui.shared.icons")
local resolver = require("atlas.core.keymaps")
local renderer = require("atlas.ui.notifications.renderer")
local state = require("atlas.ui.notifications.state")

---@type table|nil
local current_provider = nil
---@type fun()|nil
local current_refresh = nil

---@param provider table
function M.set_provider(provider)
	if current_provider ~= provider then
		state.reset()
	end
	current_provider = provider
end

---Pushed by the layout host so the popup can re-render the surrounding UI
---after mark-read / mark-done.
---@param fn fun()
function M.set_refresh(fn)
	current_refresh = fn
end

local function refresh_main()
	local ok_layout, layout = pcall(require, "atlas.ui.layout")
	if not ok_layout or not layout.is_open() then
		return
	end
	if current_refresh then
		pcall(current_refresh)
	end
end

---@param action_id string
---@param fallback string
---@return string[]
local function resolve_keys(action_id, fallback)
	local keys = resolver.resolve(action_id)
	if type(keys) == "table" and #keys > 0 then
		return keys
	end
	return { fallback }
end

local function popup_keys()
	return {
		mark_read = resolve_keys("ui.notifications_mark_read", "r"),
		mark_done = resolve_keys("ui.notifications_mark_done", "d"),
		refresh = resolve_keys("ui.notifications_refresh", "R"),
		open_in_browser = resolve_keys("ui.open_in_browser", "gx"),
		close = resolve_keys("ui.close", "q"),
	}
end

local ns = vim.api.nvim_create_namespace("atlas.notifications")

local win = nil
local buf = nil
local active_handle = nil
---@type table<integer, table>
local current_line_map = {}

local function valid_buf(b)
	return type(b) == "number" and vim.api.nvim_buf_is_valid(b)
end

local function valid_win(w)
	return type(w) == "number" and vim.api.nvim_win_is_valid(w)
end

local function cancel_active()
	if active_handle ~= nil and active_handle.cancel then
		pcall(active_handle.cancel)
	end
	active_handle = nil
end

local function compute_geometry()
	local cols = vim.o.columns
	local rows = vim.o.lines
	local width = math.max(50, math.min(100, math.floor(cols * 0.7)))
	local height = math.max(10, math.min(28, math.floor(rows * 0.6)))
	local row = math.floor((rows - height) / 2)
	local col = math.floor((cols - width) / 2)
	return width, height, row, col
end

local function close_win()
	if valid_win(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
	win = nil
end

local function delete_buf()
	if valid_buf(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
	buf = nil
end

function M.is_open()
	return valid_win(win)
end

function M.close()
	cancel_active()
	close_win()
	delete_buf()
end

---@param target_buf integer
---@param header_lines string[]
---@param header_spans table[]
---@param body_lines string[]
---@param body_spans table[]
---@param body_map table<integer, table>
---@return table<integer, table>
local function flush(target_buf, header_lines, header_spans, body_lines, body_spans, body_map)
	local all_lines = {}
	for _, l in ipairs(header_lines) do
		table.insert(all_lines, l)
	end
	for _, l in ipairs(body_lines) do
		table.insert(all_lines, l)
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = target_buf })
	vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, all_lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = target_buf })

	vim.api.nvim_buf_clear_namespace(target_buf, ns, 0, -1)

	for _, span in ipairs(header_spans or {}) do
		pcall(vim.api.nvim_buf_set_extmark, target_buf, ns, span.line, span.start_col, {
			end_row = span.line,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end

	local base = #header_lines
	for _, span in ipairs(body_spans or {}) do
		pcall(vim.api.nvim_buf_set_extmark, target_buf, ns, span.line + base, span.start_col, {
			end_row = span.line + base,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end

	local mapped = {}
	for lnum, item in pairs(body_map or {}) do
		mapped[lnum + base] = item
	end
	return mapped
end

---@param width integer
---@return string[], table[]
local function render_header(width)
	local lines = {}
	local spans = {}

	local provider = current_provider
	local provider_name = provider and provider.name or "Atlas"
	local provider_hl = provider and provider.hl_group or "Title"
	local bell = icons.general("bell")
	local title = string.format("  %s  Notifications  (%s)  ", bell, provider_name)
	local count_label = ""
	if state.is_loading then
		count_label = "loading…"
	elseif state.error then
		count_label = "error"
	else
		local total = #(state.notifications or {})
		count_label = string.format("%d unread / %d total", state.unread_count, total)
	end

	local pad = math.max(1, width - vim.api.nvim_strwidth(title) - vim.api.nvim_strwidth(count_label) - 2)
	local line = title .. string.rep(" ", pad) .. count_label .. " "
	table.insert(lines, line)
	table.insert(spans, { line = 0, start_col = 0, end_col = #title, hl_group = provider_hl })
	local count_start = #title + pad
	table.insert(spans, {
		line = 0,
		start_col = count_start,
		end_col = count_start + #count_label,
		hl_group = "AtlasTextMuted",
	})

	local sep = string.rep("─", math.max(1, width))
	table.insert(lines, sep)
	table.insert(spans, { line = 1, start_col = 0, end_col = #sep, hl_group = "AtlasBorder" })

	return lines, spans
end

local function build_footer_text()
	local keys = popup_keys()
	local items = {
		string.format("%s open", keys.open_in_browser[1]),
		string.format("%s mark read", keys.mark_read[1]),
		string.format("%s mark done", keys.mark_done[1]),
		string.format("%s refresh", keys.refresh[1]),
		string.format("%s close", keys.close[1]),
	}
	return " " .. table.concat(items, " | ") .. " "
end

local function rerender()
	if not valid_win(win) or not valid_buf(buf) then
		return
	end
	local width = vim.api.nvim_win_get_width(win)

	local header_lines, header_spans = render_header(width)
	local body_lines, body_spans, body_map

	if state.is_loading then
		body_lines = { "  Loading notifications..." }
		body_spans = { { line = 0, start_col = 0, end_col = #body_lines[1], hl_group = "AtlasTextMuted" } }
		body_map = {}
	elseif state.error then
		local err = "  Error: " .. tostring(state.error)
		body_lines = { err }
		body_spans = { { line = 0, start_col = 0, end_col = #err, hl_group = "AtlasLogError" } }
		body_map = {}
	else
		body_lines, body_spans, body_map = renderer.render(state.notifications or {}, width)
	end

	if buf ~= nil then
		current_line_map = flush(buf, header_lines, header_spans, body_lines, body_spans, body_map)
	end
end

local function first_notification_line()
	local min = nil
	for lnum, item in pairs(current_line_map) do
		if type(item) == "table" and item.kind == "notification" then
			if min == nil or lnum < min then
				min = lnum
			end
		end
	end
	return min
end

local function notification_under_cursor()
	if not valid_win(win) then
		return nil
	end
	local cursor = vim.api.nvim_win_get_cursor(win)
	local lnum = cursor[1]
	local item = current_line_map[lnum]
	if type(item) == "table" and item.kind == "notification" then
		return item.notification
	end
	for offset = 1, 3 do
		local up = current_line_map[lnum - offset]
		if type(up) == "table" and up.kind == "notification" then
			return up.notification
		end
		local down = current_line_map[lnum + offset]
		if type(down) == "table" and down.kind == "notification" then
			return down.notification
		end
	end
	return nil
end

---@param force_load boolean
local function load(force_load)
	local provider = current_provider
	if provider == nil or provider.fetch_notifications == nil then
		state.is_loading = false
		state.error = "Active provider does not support notifications"
		rerender()
		return
	end

	cancel_active()
	state.is_loading = true
	state.error = nil
	rerender()

	active_handle = provider.fetch_notifications({ force_load = force_load }, function(notifications, err)
		active_handle = nil
		state.is_loading = false
		if err then
			state.error = tostring(err)
			footer.notify("error", string.format("Failed to fetch notifications: %s", tostring(err)))
		else
			state.error = nil
			state.set_notifications(notifications)
		end
		state.last_provider_id = provider.id
		rerender()

		if valid_win(win) then
			local first = first_notification_line()
			if first ~= nil then
				pcall(vim.api.nvim_win_set_cursor, win, { first, 0 })
			end
		end
	end)
end

local function open_in_browser(notification)
	if notification == nil or not notification.url or notification.url == "" then
		footer.notify("warn", "Notification has no URL")
		return
	end
	local ok, err = pcall(vim.ui.open, notification.url)
	if not ok then
		footer.notify("error", string.format("Failed to open URL: %s", tostring(err)))
		return
	end
	footer.notify("info", "Opened in browser")
end

local function mark_read(notification)
	if notification == nil then
		return
	end
	if not notification.unread then
		footer.notify("info", "Already read")
		return
	end

	local provider = current_provider
	if provider == nil or provider.mark_notification_read == nil then
		footer.notify("warn", "Provider does not support marking as read")
		return
	end

	footer.notify("loading", "Marking as read...")
	provider.mark_notification_read(notification.id, function(ok, err)
		if not ok then
			footer.notify("error", string.format("Failed to mark as read: %s", tostring(err)))
			return
		end
		state.mark_local_read(notification.id)
		footer.notify("success", "Marked as read", 1200)
		rerender()
		refresh_main()
	end)
end

local function mark_done(notification)
	if notification == nil then
		return
	end
	local provider = current_provider
	if provider == nil or provider.mark_notification_done == nil then
		footer.notify("warn", "Provider does not support marking as done")
		return
	end

	footer.notify("loading", "Marking as done...")
	provider.mark_notification_done(notification.id, function(ok, err)
		if not ok then
			footer.notify("error", string.format("Failed to mark as done: %s", tostring(err)))
			return
		end
		state.remove_local(notification.id)
		footer.notify("success", "Marked as done", 1200)
		rerender()
		refresh_main()
	end)
end

---@param target_buf integer
local function register_keymaps(target_buf)
	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = target_buf, nowait = true, silent = true, desc = desc })
	end

	local keys = popup_keys()

	for _, k in ipairs(keys.close) do
		map(k, function()
			M.close()
		end, "Close notifications")
	end
	map("<Esc>", function()
		M.close()
	end, "Close notifications")

	for _, k in ipairs(keys.refresh) do
		map(k, function()
			load(true)
		end, "Refresh notifications")
	end

	for _, k in ipairs(keys.open_in_browser) do
		map(k, function()
			open_in_browser(notification_under_cursor())
		end, "Open notification in browser")
	end

	for _, k in ipairs(keys.mark_read) do
		map(k, function()
			mark_read(notification_under_cursor())
		end, "Mark notification as read")
	end

	for _, k in ipairs(keys.mark_done) do
		map(k, function()
			mark_done(notification_under_cursor())
		end, "Mark notification as done")
	end
end

local function ensure_buf()
	if valid_buf(buf) then
		return buf
	end
	buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "atlas-notifications", { buf = buf })
	register_keymaps(buf)
	return buf
end

function M.open()
	if M.is_open() then
		vim.api.nvim_set_current_win(win)
		return
	end

	local provider = current_provider
	if provider == nil then
		footer.notify("warn", "No active provider")
		return
	end
	if provider.fetch_notifications == nil then
		footer.notify("warn", string.format("%s does not support notifications", provider.name or "Provider"))
		return
	end

	local target_buf = ensure_buf()
	local width, height, row, col = compute_geometry()

	win = vim.api.nvim_open_win(target_buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " Notifications ",
		title_pos = "center",
		footer = build_footer_text(),
		footer_pos = "center",
		zindex = 250,
	})
	vim.api.nvim_set_option_value(
		"winhighlight",
		"Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat,FloatBorder:FloatBorder",
		{ win = win }
	)
	vim.api.nvim_set_option_value("cursorline", true, { win = win })
	vim.api.nvim_set_option_value("wrap", false, { win = win })

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			win = nil
			delete_buf()
		end,
	})

	rerender()

	if state.last_provider_id ~= provider.id or #(state.notifications or {}) == 0 then
		load(false)
	else
		local first = first_notification_line()
		if first ~= nil then
			pcall(vim.api.nvim_win_set_cursor, win, { first, 0 })
		end
	end
end

---@param opts { force_load: boolean|nil }|nil
---@param on_done fun(unread_count: integer, err: string|nil)|nil
function M.refresh_in_background(opts, on_done)
	opts = opts or {}
	on_done = on_done or function() end

	local provider = current_provider
	if provider == nil or provider.fetch_notifications == nil then
		on_done(0, "Provider has no notification support")
		return
	end

	provider.fetch_notifications({ force_load = opts.force_load == true }, function(notifications, err)
		if err then
			on_done(state.unread_count, tostring(err))
			return
		end
		state.set_notifications(notifications)
		state.last_provider_id = provider.id
		if M.is_open() then
			rerender()
		end
		on_done(state.unread_count, nil)
	end)
end

---@return integer
function M.unread_count()
	return state.unread_count or 0
end

M.state = state

return M
