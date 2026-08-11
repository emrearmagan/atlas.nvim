local M = {}

local comments = require("atlas.pulls.diff.shared.comments")
local events = require("atlas.core.events")
local notes = require("atlas.pulls.diff.shared.notes")
local comment_renderer = require("atlas.pulls.diff.shared.ui.comment_renderer")
local position = require("atlas.pulls.diff.shared.position")
local review_keymaps = require("atlas.pulls.diff.shared.keymaps")
local review_panel = require("atlas.pulls.diff.shared.ui.review_panel")
local review_threads = require("atlas.ui.components.review_threads")
local statusline = require("atlas.pulls.diff.shared.ui.statusline")

local STATUSLINE = "%!v:lua.require'atlas.pulls.diff.diffview'.statusline()"

---@type table<string, DiffFileStatus>
local FILE_STATUSES = {
	["?"] = "added",
	A = "added",
	C = "renamed",
	D = "deleted",
	M = "modified",
	R = "renamed",
	T = "type_changed",
}

---@type table<integer, AtlasDiffviewReview>
local sessions = {}

---@class AtlasDiffviewAttachOptions
---@field root string
---@field base_revision string
---@field head_revision string
---@field reload (fun(target: AtlasLoadingTarget|nil))|nil

---@class AtlasDiffviewReview
---@field tabpage integer
---@field view table
---@field context AtlasPreparedReviewContext
---@field root string
---@field base_revision string
---@field head_revision string
---@field reload (fun(target: AtlasLoadingTarget|nil))|nil
---@field session AtlasReviewSession|nil
---@field actions AtlasReviewKeymapActions|nil
---@field review_panel AtlasReviewPanel
---@field statusline AtlasDiffStatuslineState
---@field auto_open_panel boolean
---@field pending_jump table|nil
---@field group integer
---@field sync_scheduled boolean
---@field suspended boolean
---@field closed boolean
---@field session_id string
---@field additions integer
---@field deletions integer

---@param value string|nil
---@return string
local function clean_path(value)
	local path = tostring(value or "")
	path = path:gsub("\\", "/"):gsub("^%./", ""):gsub("/+$", "")
	return path
end

---@param root string
---@param path string|nil
---@return string
local function relative_path(root, path)
	path = clean_path(path)
	root = clean_path(root)
	local prefix = root ~= "" and root .. "/" or ""
	if prefix ~= "" and path:sub(1, #prefix) == prefix then
		return path:sub(#prefix + 1)
	end
	return path
end

---@param entry AtlasDiffviewReview
---@param reason string|nil
---@return table
local function event_data(entry, reason)
	local data = {
		version = 1,
		session_id = entry.session_id,
		viewer = "diffview",
		tabpage = entry.tabpage,
		root = entry.root,
		base_revision = entry.base_revision,
		head_revision = entry.head_revision,
	}
	if reason then
		data.reason = reason
	end
	return data
end

---@param session AtlasReviewSession
---@return AtlasReviewPanelData
local function review_panel_data(session)
	local review = session.review
	local note_state = session.notes
	return {
		comments = review and review.data.comments or {},
		tasks = review and review.data.tasks or {},
		notes = note_state and note_state.items or {},
		note_target = note_state and note_state.target or nil,
	}
end

---@param entry AtlasDiffviewReview
---@param level "loading"|"success"|"warn"|"error"|"info"
---@param message string
---@param duration integer|nil
local function view_notify(entry, level, message, duration)
	statusline.notify(entry.statusline, level, message, duration)
end

---@param entry AtlasDiffviewReview
---@param focus boolean
---@return boolean opened
local function open_review_panel(entry, focus)
	local panel = entry.review_panel
	local layout = entry.view.cur_layout
	local anchor = layout and layout.b and layout.b.id or nil
	if not anchor then
		return false
	end
	local win = review_panel.open(panel, anchor, focus)
	if win then
		vim.api.nvim_set_option_value("statusline", STATUSLINE, { win = win, scope = "local" })
	end
	return win ~= nil
end

---@param entry AtlasDiffviewReview
local function toggle_review_panel(entry)
	local panel = entry.review_panel
	if panel.win and vim.api.nvim_win_is_valid(panel.win) then
		review_panel.close(panel)
		return
	end
	open_review_panel(entry, true)
end

---@param entry AtlasDiffviewReview
---@return boolean
local function finish_pending_jump(entry)
	local pending = entry.pending_jump
	local session = entry.session
	local document = session and session.document
	if
		not pending
		or not session
		or not document
		or (document.old.path ~= pending.path and document.new.path ~= pending.path)
	then
		return false
	end
	entry.pending_jump = nil
	local side, line
	if pending.comment then
		side, line = position.location(pending.comment.inline)
		if session.review then
			session.review.expanded_threads[review_threads.comment_key(pending.comment)] = true
		end
	elseif document.binary or document.status == "deleted" then
		view_notify(entry, "info", "This note's file is no longer in the diff")
		return true
	else
		side, line = "RIGHT", pending.note.line
	end
	local source = side == "LEFT" and document.old.lines or document.new.lines
	local target = side == "LEFT" and session.left or session.right
	if
		not side
		or not line
		or line < 1
		or #source == 0
		or not target.win
		or not vim.api.nvim_win_is_valid(target.win)
	then
		view_notify(entry, "info", "This review item's diff position is outdated")
		return true
	end
	session.refresh_ui()
	line = math.min(line, #source)
	vim.api.nvim_win_set_cursor(target.win, { line, 0 })
	vim.api.nvim_win_call(target.win, function()
		pcall(vim.cmd.normal, { "zvzz", bang = true })
	end)
	if vim.api.nvim_get_current_tabpage() == entry.tabpage then
		if pending.focus_diff then
			vim.api.nvim_set_current_win(target.win)
		elseif entry.review_panel.win and vim.api.nvim_win_is_valid(entry.review_panel.win) then
			vim.api.nvim_set_current_win(entry.review_panel.win)
		end
	end
	return true
end

---@param window table
---@return string[]
local function buffer_lines(window)
	if window.file.nulled or window.file.binary then
		return {}
	end
	return vim.api.nvim_buf_get_lines(window.file.bufnr, 0, -1, false)
end

---@param lines string[]
---@return string
local function content(lines)
	return #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
end

---@param old_lines string[]
---@param new_lines string[]
---@return AtlasDiffLineChange[]
local function line_changes(old_lines, new_lines)
	local result = {}
	local changes = vim.diff(content(old_lines), content(new_lines), {
		algorithm = "histogram",
		result_type = "indices",
	})
	for _, change in ipairs(changes) do
		local old_start, old_count, new_start, new_count = unpack(change)
		table.insert(result, {
			old_start = old_start,
			old_count = old_count,
			new_start = new_start,
			new_count = new_count,
		})
	end
	return result
end

---@param entry AtlasDiffviewReview
local function reload(entry)
	if not entry.reload then
		return
	end
	local callback = entry.reload
	vim.cmd("tabnew")
	local win = vim.api.nvim_get_current_win()
	local target = {
		tabpage = vim.api.nvim_get_current_tabpage(),
		buf = vim.api.nvim_get_current_buf(),
		win = win,
		number = vim.wo[win].number,
		relativenumber = vim.wo[win].relativenumber,
		statuscolumn = vim.wo[win].statuscolumn,
		statusline = vim.wo[win].statusline,
		winbar = vim.wo[win].winbar,
	}
	local ok, err = pcall(function()
		entry.view:close()
		require("diffview.lib").dispose_view(entry.view)
	end)
	if not ok then
		vim.cmd("tabclose")
		view_notify(entry, "error", "Unable to close Diffview: " .. tostring(err))
		return
	end
	M.detach(entry.tabpage, "reload")
	vim.schedule(function()
		callback(target)
	end)
end

---@param entry AtlasDiffviewReview
local function map_review(entry)
	local session = entry.session
	local actions = entry.actions
	if not session or not actions then
		return
	end
	local view = entry.view
	local panel_buf = view.panel and view.panel.bufid
	local buffers = { session.left.buf, session.right.buf }
	if panel_buf and vim.api.nvim_buf_is_valid(panel_buf) then
		table.insert(buffers, panel_buf)
	end
	review_keymaps.register(session, actions, {
		buffers = buffers,
		reload = entry.reload and function()
			reload(entry)
		end or nil,
	})
	review_panel.register_toggle(entry.review_panel, buffers)
end

---@param entry AtlasDiffviewReview
---@param session AtlasReviewSession
local function refresh_scroll(entry, session)
	comments.render(session)
	notes.render(session)
	review_panel.render(entry.review_panel, review_panel_data(session))
	local layout = entry.view.cur_layout
	if layout and layout.sync_scroll then
		pcall(layout.sync_scroll, layout)
	end
	vim.cmd("redrawstatus")
end

---@param entry AtlasDiffviewReview
local function suspend(entry)
	if entry.session then
		comment_renderer.clear_comments(entry.session.left.buf)
		comment_renderer.clear_comments(entry.session.right.buf)
		notes.clear(entry.session)
		entry.session.document = nil
	end
	if not entry.suspended then
		entry.suspended = true
		view_notify(entry, "warn", "Atlas review overlays require a two-pane Diffview layout")
	end
end

---@param entry AtlasDiffviewReview
---@return boolean
local function sync(entry)
	if entry.closed or not vim.api.nvim_tabpage_is_valid(entry.tabpage) then
		return false
	end
	local view = entry.view
	local current = view.cur_entry
	local layout = view.cur_layout
	if not view.ready or not current or not layout then
		return false
	end
	local layout_name = tostring(layout.name or "")
	if not layout_name:match("^diff2_") then
		suspend(entry)
		return false
	end
	if not layout.a:is_file_open() or not layout.b:is_file_open() then
		return false
	end
	entry.additions, entry.deletions = 0, 0
	for _, file in view.files:iter() do
		local stats = file.stats
		if stats then
			entry.additions = entry.additions + (stats.additions or 0)
			entry.deletions = entry.deletions + (stats.deletions or 0)
		end
	end

	local path = relative_path(entry.root, current.path)
	local old_path = relative_path(entry.root, current.oldpath)
	if old_path == "" then
		old_path = path
	end
	if path == "" then
		return false
	end
	local status = FILE_STATUSES[tostring(current.status or ""):sub(1, 1)] or "modified"
	local old_lines = buffer_lines(layout.a)
	local new_lines = buffer_lines(layout.b)
	local binary = layout.a.file.binary == true or layout.b.file.binary == true
	local changes = binary and {} or line_changes(old_lines, new_lines)
	local previous = entry.session
	local buffers_changed = not previous
		or previous.left.buf ~= layout.a.file.bufnr
		or previous.right.buf ~= layout.b.file.bufnr
	if previous and buffers_changed then
		comment_renderer.clear_comments(previous.left.buf)
		comment_renderer.clear_comments(previous.right.buf)
		notes.clear(previous)
	end
	local resumed = entry.suspended
	entry.suspended = false
	local session = previous or { tabpage = entry.tabpage, closing = false }
	session.head_revision = entry.head_revision
	session.layout = "side-by-side"
	session.left = { buf = layout.a.file.bufnr, win = layout.a.id }
	session.right = { buf = layout.b.file.bufnr, win = layout.b.id }
	session.document = {
		status = status,
		old = { path = old_path, lines = old_lines },
		new = { path = path, lines = new_lines },
		changes = changes,
		binary = binary,
	}
	entry.session = session
	vim.api.nvim_set_option_value("statusline", STATUSLINE, { win = layout.a.id, scope = "local" })
	vim.api.nvim_set_option_value("statusline", STATUSLINE, { win = layout.b.id, scope = "local" })
	vim.cmd("redrawstatus")
	session.refresh_ui = function()
		refresh_scroll(entry, session)
	end
	session.review_view = {
		notify = function(level, message, duration)
			view_notify(entry, level, message, duration)
		end,
		register_keymaps = function(actions)
			entry.actions = actions
			map_review(entry)
		end,
	}
	if not session.review then
		notes.attach(session, entry.context)
		local ok, err = pcall(comments.attach, session, entry.context)
		if not ok then
			comments.detach(session)
			view_notify(entry, "error", "Unable to load comments: " .. tostring(err))
		else
			events.emit("AtlasReviewAttached", event_data(entry))
		end
	else
		if buffers_changed or resumed then
			map_review(entry)
		end
		session.refresh_ui()
	end
	if entry.auto_open_panel and open_review_panel(entry, false) then
		entry.auto_open_panel = false
	end
	finish_pending_jump(entry)
	return true
end

---@param entry AtlasDiffviewReview
local function schedule_sync(entry)
	if entry.closed or entry.sync_scheduled then
		return
	end
	entry.sync_scheduled = true
	vim.schedule(function()
		entry.sync_scheduled = false
		sync(entry)
	end)
end

---@param entry AtlasDiffviewReview
---@param item AtlasReviewPanelSelection
---@param focus_diff boolean
local function select_review_item(entry, item, focus_diff)
	local path
	local pending = { focus_diff = focus_diff }
	if item.kind == "note" and item.note then
		path, pending.note = relative_path(entry.root, item.note.file_path), item.note
	elseif item.comment and item.comment.inline then
		path, pending.comment = relative_path(entry.root, item.comment.inline.path), item.comment
	else
		view_notify(entry, "info", "This comment is not attached to the diff")
		return
	end
	if path == "" then
		view_notify(entry, "info", "This review item's file is no longer in the diff")
		return
	end
	pending.path = path
	entry.pending_jump = pending
	if finish_pending_jump(entry) then
		return
	end
	for _, file in entry.view.files:iter() do
		if relative_path(entry.root, file.path) == path or relative_path(entry.root, file.oldpath) == path then
			entry.view:set_file(file, false, true)
			return
		end
	end
	entry.pending_jump = nil
	view_notify(entry, "info", "This review item's file is no longer in the diff")
end

---@param entry AtlasDiffviewReview
local function register_events(entry)
	vim.api.nvim_create_autocmd("User", {
		group = entry.group,
		pattern = { "DiffviewDiffBufWinEnter", "DiffviewViewPostLayout" },
		callback = function()
			if vim.api.nvim_get_current_tabpage() == entry.tabpage then
				schedule_sync(entry)
			end
		end,
	})
	vim.api.nvim_create_autocmd("User", {
		group = entry.group,
		pattern = "DiffviewViewClosed",
		callback = function()
			vim.schedule(function()
				if not entry.closed and not vim.api.nvim_tabpage_is_valid(entry.tabpage) then
					M.detach(entry.tabpage, "viewer_closed")
				end
			end)
		end,
	})
end

---@param context AtlasPreparedReviewContext
---@param view table
---@param opts AtlasDiffviewAttachOptions
---@return string|nil err
function M.attach(context, view, opts)
	local tabpage = view and view.tabpage
	if not tabpage or not vim.api.nvim_tabpage_is_valid(tabpage) then
		return "Diffview session is unavailable"
	end
	M.detach(tabpage, "replaced")
	local diff_config = (require("atlas.config").options.pulls or {}).diff or {}
	---@type AtlasDiffviewReview
	local entry
	entry = {
		tabpage = tabpage,
		view = view,
		context = context,
		root = clean_path(opts.root),
		base_revision = opts.base_revision,
		head_revision = opts.head_revision,
		reload = opts.reload,
		session = nil,
		actions = nil,
		review_panel = review_panel.create(string.format("atlas-diffview://%d/review", tabpage), {
			on_toggle = function()
				toggle_review_panel(entry)
			end,
			on_select = function(item, focus_diff)
				select_review_item(entry, item, focus_diff)
			end,
			on_refresh = function()
				if entry.session then
					comments.reload(entry.session)
					notes.reload(entry.session)
				end
			end,
			on_comment_action = function(action, comment)
				if entry.session then
					comments.run_action(entry.session, action, comment)
				end
			end,
			on_edit_note = function(note)
				if entry.session then
					notes.edit(entry.session, note)
				end
			end,
			on_delete_note = function(note)
				if entry.session then
					notes.delete(entry.session, note)
				end
			end,
		}),
		statusline = statusline.new(),
		auto_open_panel = diff_config.show_review_panel == true,
		pending_jump = nil,
		group = vim.api.nvim_create_augroup("AtlasDiffviewReview" .. tabpage, { clear = true }),
		sync_scheduled = false,
		suspended = false,
		closed = false,
		session_id = events.new_id("diffview"),
		additions = 0,
		deletions = 0,
	}
	review_panel.register_keymaps(entry.review_panel)
	review_panel.register_toggle(entry.review_panel, { entry.review_panel.buf })
	sessions[tabpage] = entry
	register_events(entry)
	schedule_sync(entry)
	return nil
end

---@param tabpage integer|nil
---@param reason string|nil
function M.detach(tabpage, reason)
	tabpage = tabpage or vim.api.nvim_get_current_tabpage()
	local entry = sessions[tabpage]
	if not entry then
		return
	end
	sessions[tabpage] = nil
	entry.closed = true
	statusline.dispose(entry.statusline)
	review_panel.delete(entry.review_panel)
	local attached = entry.session and entry.session.review ~= nil
	if entry.session then
		entry.session.closing = true
		comments.detach(entry.session)
		notes.detach(entry.session)
	end
	pcall(vim.api.nvim_del_augroup_by_id, entry.group)
	if attached then
		events.emit("AtlasReviewDetached", event_data(entry, reason or "viewer_closed"))
	end
end

---@return string
function M.statusline()
	local entry = sessions[vim.api.nvim_get_current_tabpage()]
	local session = entry and entry.session
	if not session then
		return ""
	end
	local pr = entry.context.pr
	return statusline.render(
		string.format("#%s %s", tostring(pr.id), tostring(pr.title)),
		entry.additions,
		entry.deletions,
		session.review,
		session.notes,
		entry.statusline
	)
end

return M
