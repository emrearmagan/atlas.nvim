local M = {}

local comments = require("atlas.pulls.diff.comments")
local config = require("atlas.config")
local hints = require("atlas.pulls.diff.ui.hints")
local notes = require("atlas.pulls.diff.notes")
local position = require("atlas.pulls.diff.position")
local review_keymaps = require("atlas.pulls.diff.keymaps")
local review_panel = require("atlas.pulls.diff.ui.review_panel")
local session_api = require("atlas.pulls.diff.session")
local statusline = require("atlas.pulls.diff.ui.statusline")
local ui_comments = require("atlas.pulls.diff.ui.comments")

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

---@class AtlasDiffviewState
---@field view table
---@field group integer
---@field sync_scheduled boolean
---@field suspended boolean
---@field auto_open_panel boolean
---@field pending_jump { path: string, comment: PullsComment|nil, note: AtlasNote|nil, focus_diff: boolean }|nil
---@field additions integer
---@field deletions integer
---@field closed boolean
---@field reloading boolean
---@field reload_view (fun())|nil

---@param value string|nil
---@return string
local function clean_path(value)
	local path = tostring(value or "")
	return (path:gsub("\\", "/"):gsub("^%./", ""):gsub("/+$", ""))
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
		result[#result + 1] = {
			old_start = old_start,
			old_count = old_count,
			new_start = new_start,
			new_count = new_count,
		}
	end
	return result
end

---@param session AtlasDiffSession
---@param focus boolean
---@return boolean opened
local function open_review_panel(session, focus)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	if state.closed then
		return false
	end
	local layout = state.view and state.view.cur_layout or nil
	local anchor = layout and layout.b and layout.b.id or nil
	if not anchor or not vim.api.nvim_win_is_valid(anchor) then
		anchor = layout and layout.a and layout.a.id or nil
	end
	if not anchor or not session.review_panel then
		return false
	end
	local win = review_panel.open(session.review_panel, anchor, focus)
	if win then
		statusline.attach(win)
	end
	return win ~= nil
end

---@param session AtlasDiffSession
---@param focus boolean|nil
local function toggle_review_panel(session, focus)
	local panel = session.review_panel
	if not panel then
		return
	end
	if panel.win and vim.api.nvim_win_is_valid(panel.win) then
		review_panel.close(panel)
		return
	end
	open_review_panel(session, focus ~= false)
end

---@param session AtlasDiffSession
local function finish_pending_jump(session)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	local pending = state.pending_jump
	local current = session.current
	local document = current and current.document or nil
	if
		not pending
		or not current
		or not document
		or (document.old.path ~= pending.path and document.new.path ~= pending.path)
	then
		return
	end
	state.pending_jump = nil

	---@type AtlasDiffSide|nil
	local side = pending.note and "RIGHT" or nil
	local line = pending.note and pending.note.line or nil
	if pending.comment then
		side, line = position.comment(document, pending.comment)
	elseif document.binary or document.status == "deleted" then
		session_api.notify(session, "info", "This note's file is no longer in the diff")
		return
	end

	local target = side == "LEFT" and current.left or current.right
	if
		not side
		or not line
		or line < 1
		or ((not pending.comment or not pending.comment.file) and #(side == "LEFT" and document.old.lines or document.new.lines) == 0)
		or not target.win
		or not vim.api.nvim_win_is_valid(target.win)
	then
		session_api.notify(session, "info", "This review item's diff position is outdated")
		return
	end

	line = math.min(line, vim.api.nvim_buf_line_count(target.buf))
	vim.api.nvim_win_set_cursor(target.win, { line, 0 })
	vim.api.nvim_win_call(target.win, function()
		pcall(vim.cmd.normal, { "zvzz", bang = true })
	end)
	if vim.api.nvim_get_current_tabpage() == session.tabpage then
		if pending.focus_diff then
			vim.api.nvim_set_current_win(target.win)
		elseif
			session.review_panel
			and session.review_panel.win
			and vim.api.nvim_win_is_valid(session.review_panel.win)
		then
			vim.api.nvim_set_current_win(session.review_panel.win)
		end
	end
end

---@param session AtlasDiffSession
local function reload_view(session)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	if state.closed or state.reloading or not session.reload then
		return
	end
	local reload = session.reload
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
	state.reloading = true
	local ok, err = pcall(function()
		state.view:close()
		require("diffview.lib").dispose_view(state.view)
	end)
	if not ok then
		state.reloading = false
		vim.cmd("tabclose")
		session_api.notify(session, "error", "Unable to close Diffview: " .. tostring(err))
		return
	end
	M.detach(session, "reload")
	vim.schedule(function()
		reload(target)
	end)
end

---@param session AtlasDiffSession
local function register_review_buffers(session)
	local current = session.current
	if not current then
		return
	end
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	local candidates = { current.left.buf, current.right.buf }
	local diffview_panel_buf = state.view.panel and state.view.panel.bufid or nil
	if diffview_panel_buf then
		candidates[#candidates + 1] = diffview_panel_buf
	end
	local buffers, seen = {}, {}
	for _, buf in ipairs(candidates) do
		if buf and not seen[buf] and vim.api.nvim_buf_is_valid(buf) then
			seen[buf] = true
			buffers[#buffers + 1] = buf
		end
	end
	review_keymaps.register(session, {
		buffers = buffers,
		reload = state.reload_view,
		help_key = "gA",
		file_buffers = diffview_panel_buf and { diffview_panel_buf } or nil,
		add_file_comment = function(pending)
			local file = state.view:infer_cur_file()
			if file then
				comments.add_to_file(session, {
					path = relative_path(session.source.root, file.path),
					old_path = file.oldpath and relative_path(session.source.root, file.oldpath) or nil,
				}, pending)
			end
		end,
	})
	if session.review_panel then
		review_panel.register_toggle(session.review_panel, buffers)
	end
end

---@param session AtlasDiffSession
local function render_view(session)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	if state.closed then
		return
	end
	local layout = state.view and state.view.cur_layout or nil
	if layout and layout.sync_scroll then
		pcall(layout.sync_scroll, layout)
	end
end

---@param session AtlasDiffSession
local function suspend(session)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	if state.closed then
		return
	end
	if session.current then
		ui_comments.clear(session.current)
		notes.clear(session.current)
		hints.clear(session.current)
		session.current = nil
	end
	if not state.suspended then
		state.suspended = true
		session_api.notify(session, "warn", "Atlas review overlays require a two-pane Diffview layout")
	end
end

---@param session AtlasDiffSession
---@return boolean synced
local function sync(session)
	if
		session.closed
		or not session.tabpage
		or not vim.api.nvim_tabpage_is_valid(session.tabpage)
		or session_api.get(session.tabpage) ~= session
	then
		return false
	end
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	if state.closed then
		return false
	end
	local view = state.view
	local current = view.cur_entry
	local layout = view.cur_layout
	if not view.ready or not current or not layout then
		return false
	end
	if not tostring(layout.name or ""):match("^diff2_") then
		suspend(session)
		return false
	end
	if not layout.a:is_file_open() or not layout.b:is_file_open() then
		return false
	end

	state.additions, state.deletions = 0, 0
	for _, file in view.files:iter() do
		if file.stats then
			state.additions = state.additions + (file.stats.additions or 0)
			state.deletions = state.deletions + (file.stats.deletions or 0)
		end
	end

	local path = relative_path(session.source.root, current.path)
	local old_path = relative_path(session.source.root, current.oldpath)
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
	local previous = session.current
	local buffers_changed = not previous
		or previous.left.buf ~= layout.a.file.bufnr
		or previous.right.buf ~= layout.b.file.bufnr
	local current_view = {
		layout = "side-by-side",
		document = {
			status = status,
			old = { path = old_path, lines = old_lines },
			new = { path = path, lines = new_lines },
			changes = binary and {} or line_changes(old_lines, new_lines),
			binary = binary,
		},
		left = { buf = layout.a.file.bufnr, win = layout.a.id },
		right = { buf = layout.b.file.bufnr, win = layout.b.id },
	}
	state.suspended = false
	statusline.attach(current_view.left.win)
	statusline.attach(current_view.right.win)
	session_api.set_current(session, current_view)
	session_api.review_attached(session)
	if buffers_changed then
		register_review_buffers(session)
	end
	if state.auto_open_panel and open_review_panel(session, false) then
		state.auto_open_panel = false
	end
	finish_pending_jump(session)
	return true
end

---@param session AtlasDiffSession
local function schedule_sync(session)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	if session.closed or state.closed or state.sync_scheduled then
		return
	end
	state.sync_scheduled = true
	vim.schedule(function()
		if session.viewer_state ~= state or state.closed then
			return
		end
		state.sync_scheduled = false
		sync(session)
	end)
end

---@param session AtlasDiffSession
---@param item AtlasDiffReviewPanelSelection
---@param focus_diff boolean
local function focus_item(session, item, focus_diff)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	if state.closed then
		return
	end
	local pending = { focus_diff = focus_diff }
	local note = item.kind == "note" and item.note or nil
	local comment = item.comment and (item.comment.file or item.comment.inline) and item.comment or nil
	if not note and not comment then
		session_api.notify(session, "info", "This comment is not attached to the diff")
		return
	end
	local target = comment and (comment.file or comment.inline) or nil
	local path = relative_path(session.source.root, note and note.file_path or target.path)
	pending.note = note
	pending.comment = comment
	if path == "" then
		session_api.notify(session, "info", "This review item's file is no longer in the diff")
		return
	end
	pending.path = path
	state.pending_jump = pending
	finish_pending_jump(session)
	if not state.pending_jump then
		return
	end
	for _, file in state.view.files:iter() do
		if
			relative_path(session.source.root, file.path) == path
			or relative_path(session.source.root, file.oldpath) == path
		then
			state.view:set_file(file, false, true)
			return
		end
	end
	state.pending_jump = nil
	session_api.notify(session, "info", "This review item's file is no longer in the diff")
end

---@param session AtlasDiffSession
local function register_events(session)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	vim.api.nvim_create_autocmd("User", {
		group = state.group,
		pattern = { "DiffviewDiffBufWinEnter", "DiffviewViewPostLayout" },
		callback = function()
			if
				session.viewer_state == state
				and not state.closed
				and vim.api.nvim_get_current_tabpage() == session.tabpage
			then
				schedule_sync(session)
			end
		end,
	})
	vim.api.nvim_create_autocmd("User", {
		group = state.group,
		pattern = "DiffviewViewClosed",
		callback = function()
			vim.schedule(function()
				if
					session.viewer_state == state
					and not state.reloading
					and not state.closed
					and not session.closed
					and session.tabpage
					and not vim.api.nvim_tabpage_is_valid(session.tabpage)
				then
					M.detach(session, "viewer_closed")
				end
			end)
		end,
	})
end

---@param session AtlasDiffSession
---@param view table
---@param tabpage integer
local function attach(session, view, tabpage)
	local diff_config = (config.options.pulls or {}).diff or {}
	---@type AtlasDiffviewState
	local state = {
		view = view,
		group = vim.api.nvim_create_augroup("AtlasDiffview" .. tabpage, { clear = true }),
		sync_scheduled = false,
		suspended = false,
		auto_open_panel = diff_config.show_review_panel == true
			and (session.review ~= nil or session.note_target ~= nil),
		pending_jump = nil,
		additions = 0,
		deletions = 0,
		closed = false,
		reloading = false,
	}
	session.viewer_state = state
	state.reload_view = function()
		reload_view(session)
	end

	if session.review or session.note_target then
		local panel =
			session_api.create_review_panel(session, string.format("atlas-diff-diffview://%d/review", tabpage))
		review_panel.configure(panel)
		review_panel.register_keymaps(panel)
	end
	register_events(session)
	session_api.attach(session, {
		tabpage = tabpage,
		notify = function(level, message, duration)
			statusline.notify(session.statusline, level, message, duration)
		end,
		focus_item = function(item, focus_diff)
			focus_item(session, item, focus_diff)
		end,
		render_view = function()
			render_view(session)
		end,
		toggle_review_panel = function(focus)
			toggle_review_panel(session, focus)
		end,
	})
	schedule_sync(session)
end

---@param session AtlasDiffSession
---@param loading_view AtlasLoadingView
---@param on_done fun(err: string|nil)
---@return nil
function M.open(session, loading_view, on_done)
	local finished = false
	local function finish(err)
		if finished then
			return
		end
		finished = true
		loading_view:finish()
		vim.schedule(function()
			on_done(err)
		end)
	end

	local source = session.source
	local range = source.head_revision and source.base_revision .. "..." .. source.head_revision or source.base_revision
	local ok, view = pcall(vim.api.nvim_win_call, loading_view.win, function()
		vim.cmd("tcd " .. vim.fn.fnameescape(source.root))
		vim.api.nvim_cmd({
			cmd = "DiffviewOpen",
			args = { range },
		}, {})
		return require("diffview.lib").get_current_view()
	end)
	if not ok then
		finish(tostring(view))
		return nil
	end
	local tabpage = view and view.tabpage or nil
	if not tabpage or not vim.api.nvim_tabpage_is_valid(tabpage) then
		finish("Diffview session is unavailable")
		return nil
	end

	local attached, attach_err = pcall(attach, session, view, tabpage)
	if not attached then
		local state = session.viewer_state --[[@as AtlasDiffviewState]]
		if state.view == view then
			M.detach(session, "attach_failed")
		end
		finish("Unable to attach review to Diffview: " .. tostring(attach_err))
		return nil
	end
	finish(nil)
	return nil
end

---@param session AtlasDiffSession
---@param reason string|nil
function M.detach(session, reason)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	if session.closed or not state or state.closed then
		return
	end
	state.closed = true
	state.pending_jump = nil
	pcall(vim.api.nvim_del_augroup_by_id, state.group)
	session_api.detach(session, reason)
end

return M
