local M = {}

local notify = require("atlas.core.notify")
local statusline = require("atlas.ui.statusline")
local icons = require("atlas.ui.shared.icons")
local resolver = require("atlas.core.keymaps")
local renderer = require("atlas.ui.notifications.renderer")
local state = require("atlas.ui.notifications.state")

---@param action_id AtlasKeymapActionId|string
---@return string[]
local function resolve_keys(action_id)
	return resolver.resolve(action_id) or {}
end

local function popup_keys()
	return {
		mark_read = resolve_keys("ui.notifications.mark_read"),
		mark_done = resolve_keys("ui.notifications.mark_done"),
		refresh = resolve_keys("ui.refresh_view"),
		open = resolve_keys("ui.select"),
		open_in_browser = resolve_keys("ui.open_in_browser"),
		close = resolve_keys("ui.close"),
	}
end

local ns = vim.api.nvim_create_namespace("atlas.notifications")

local win = nil
local active_handle = nil
local loading = false
local load_error = nil
---@type table<integer, AtlasNotification>
local current_line_map = {}

local function valid_win(w)
	return type(w) == "number" and vim.api.nvim_win_is_valid(w)
end

---@param provider PullsProvider|IssuesProvider
---@return AtlasNotificationsCapability
local function capability(provider)
	return assert(provider.capabilities.notifications)
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

function M.close()
	if valid_win(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
end

---@param target_buf integer
---@param lines string[]
---@param spans table[]
local function flush(target_buf, lines, spans)
	vim.api.nvim_set_option_value("modifiable", true, { buf = target_buf })
	vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = target_buf })

	vim.api.nvim_buf_clear_namespace(target_buf, ns, 0, -1)

	for _, span in ipairs(spans) do
		pcall(vim.api.nvim_buf_set_extmark, target_buf, ns, span.line, span.start_col, {
			end_row = span.line,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
end

---@param provider PullsProvider|IssuesProvider
local function window_title(provider)
	local bell = icons.get("bell")
	return string.format(" %s Notifications (%s) ", bell, provider.name)
end

---@param provider PullsProvider|IssuesProvider
local function build_footer_text(provider)
	local keys = popup_keys()
	local items = {}
	if keys.open[1] then
		table.insert(items, keys.open[1] .. " open")
	end
	if keys.open_in_browser[1] then
		table.insert(items, keys.open_in_browser[1] .. " browser")
	end
	if keys.mark_read[1] and capability(provider).mark_read then
		table.insert(items, keys.mark_read[1] .. " mark read")
	end
	if keys.mark_done[1] then
		table.insert(items, keys.mark_done[1] .. " mark done")
	end
	if keys.refresh[1] then
		table.insert(items, keys.refresh[1] .. " refresh")
	end
	if keys.close[1] then
		table.insert(items, keys.close[1] .. " close")
	end
	return " " .. table.concat(items, " | ") .. " "
end

---@param provider PullsProvider|IssuesProvider
local function rerender(provider)
	if not valid_win(win) then
		return
	end
	local body_lines, body_spans, body_map
	if loading then
		body_lines, body_spans, body_map = renderer.message("Loading notifications...", "AtlasTextMuted")
	elseif load_error then
		body_lines, body_spans, body_map = renderer.message("Error: " .. load_error, "AtlasLogError")
	else
		body_lines, body_spans, body_map = renderer.render(state.get(provider.id), vim.api.nvim_win_get_width(win))
	end

	flush(vim.api.nvim_win_get_buf(win), body_lines, body_spans)
	current_line_map = body_map
end

local function focus_first()
	if valid_win(win) then
		pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
	end
end

---@return AtlasNotification|nil
local function notification_under_cursor()
	if not valid_win(win) then
		return nil
	end
	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	return current_line_map[lnum] or current_line_map[lnum - 1]
end

---@param provider PullsProvider|IssuesProvider
---@param force_refresh boolean
local function load(provider, force_refresh)
	cancel_active()
	loading = true
	load_error = nil
	rerender(provider)

	active_handle = capability(provider).fetch({ force_refresh = force_refresh }, function(notifications, err)
		active_handle = nil
		loading = false
		if err then
			load_error = tostring(err)
			notify.error(string.format("Failed to fetch notifications: %s", load_error))
		else
			state.set(provider.id, notifications or {})
		end
		rerender(provider)
		focus_first()
	end)
end

---@param notification AtlasNotification|nil
local function open_in_browser(notification)
	if notification == nil or not notification.url or notification.url == "" then
		notify.warn("Notification has no URL")
		return
	end
	local ok, err = pcall(vim.ui.open, notification.url)
	if not ok then
		notify.error(string.format("Failed to open URL: %s", tostring(err)))
		return
	end
	notify.info("Opened in browser")
end

---@param provider PullsProvider|IssuesProvider
---@param notification AtlasNotification|nil
---@param on_update fun()|nil
---@param opts { quiet: boolean|nil }|nil
local function mark_read(provider, notification, on_update, opts)
	local mark = capability(provider).mark_read
	if notification == nil or not notification.unread or mark == nil then
		return
	end

	local quiet = opts and opts.quiet
	if not quiet then
		notify.loading("Marking as read...")
	end

	mark(notification.id, function(ok, err)
		if not ok then
			notify.error(string.format("Failed to mark as read: %s", tostring(err)))
			return
		end

		state.mark_local_read(provider.id, notification.id)
		if not quiet then
			notify.success("Marked as read", { timeout = 1200 })
		end

		rerender(provider)
		if on_update then
			on_update()
		end
	end)
end

---@param provider PullsProvider|IssuesProvider
---@param notification AtlasNotification|nil
---@param on_update fun()|nil
local function open(provider, notification, on_update)
	if notification == nil then
		return
	end

	M.close()
	if not capability(provider).open(notification) then
		open_in_browser(notification)
	end

	mark_read(provider, notification, on_update, { quiet = true })
end

---@param provider PullsProvider|IssuesProvider
---@param notification AtlasNotification|nil
---@param on_update fun()|nil
local function mark_done(provider, notification, on_update)
	if notification == nil then
		return
	end

	notify.loading("Marking as done...")
	capability(provider).mark_done(notification.id, function(ok, err)
		if not ok then
			notify.error(string.format("Failed to mark as done: %s", tostring(err)))
			return
		end
		state.remove_local(provider.id, notification.id)
		notify.success("Marked as done", { timeout = 1200 })
		rerender(provider)
		if on_update then
			on_update()
		end
	end)
end

---@param target_buf integer
---@param provider PullsProvider|IssuesProvider
---@param on_update fun()|nil
local function register_keymaps(target_buf, provider, on_update)
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
			load(provider, true)
		end, "Refresh notifications")
	end

	for _, k in ipairs(keys.open) do
		map(k, function()
			open(provider, notification_under_cursor(), on_update)
		end, "Open notification")
	end

	for _, k in ipairs(keys.open_in_browser) do
		map(k, function()
			open_in_browser(notification_under_cursor())
		end, "Open notification in browser")
	end

	if capability(provider).mark_read then
		for _, k in ipairs(keys.mark_read) do
			map(k, function()
				mark_read(provider, notification_under_cursor(), on_update)
			end, "Mark notification as read")
		end
	end

	for _, k in ipairs(keys.mark_done) do
		map(k, function()
			mark_done(provider, notification_under_cursor(), on_update)
		end, "Mark notification as done")
	end
end

---@param provider PullsProvider|IssuesProvider
---@param on_update fun()|nil
---@return integer
local function create_buf(provider, on_update)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "atlas-ui.notifications", { buf = buf })
	pcall(vim.treesitter.stop, buf)
	register_keymaps(buf, provider, on_update)
	return buf
end

---@param provider PullsProvider|IssuesProvider|nil
---@param on_update fun()|nil
function M.open(provider, on_update)
	if valid_win(win) then
		vim.api.nvim_set_current_win(win)
		return
	end

	if provider == nil then
		notify.warn("No active provider")
		return
	end
	if provider.capabilities.notifications == nil then
		notify.warn(string.format("%s does not support notifications", provider.name))
		return
	end

	local source_win = vim.api.nvim_get_current_win()
	local width, height, row, col = compute_geometry()
	loading = false
	load_error = nil

	win = vim.api.nvim_open_win(create_buf(provider, on_update), true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = window_title(provider),
		title_pos = "center",
		footer = build_footer_text(provider),
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
	statusline.inherit(win, source_win)

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			cancel_active()
			win = nil
		end,
	})

	rerender(provider)

	if #state.get(provider.id) == 0 then
		load(provider, false)
	else
		focus_first()
	end
end

---@param provider PullsProvider|IssuesProvider
---@return integer
function M.unread_count(provider)
	local count = 0
	for _, n in ipairs(state.get(provider.id)) do
		if n.unread then
			count = count + 1
		end
	end
	return count
end

---@param provider PullsProvider|IssuesProvider
---@param on_done fun()
function M.refresh(provider, on_done)
	capability(provider).fetch(nil, function(notifications, err)
		if err then
			return
		end
		state.set(provider.id, notifications or {})
		on_done()
	end)
end

return M
