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

local STATUSLINE = "%!v:lua.require'atlas.pulls.diff.codediff'.statusline()"

---@type table<string, DiffFileStatus>
local FILE_STATUSES = {
	A = "added",
	D = "deleted",
	M = "modified",
	R = "renamed",
	T = "type_changed",
}

---@type table<integer, AtlasCodeDiffReview>
local sessions = {}
local READY_RETRIES = 80

---@class AtlasCodeDiffRange
---@field start_line integer
---@field end_line integer

---@class AtlasCodeDiffChange
---@field original AtlasCodeDiffRange
---@field modified AtlasCodeDiffRange

---@class AtlasCodeDiffSession
---@field original { relative: string|nil }|nil
---@field modified { relative: string|nil }|nil
---@field original_bufnr integer|nil
---@field modified_bufnr integer|nil
---@field original_win integer|nil
---@field modified_win integer|nil
---@field layout "side-by-side"|"inline"
---@field stored_diff_result { changes: AtlasCodeDiffChange[] }|nil

---@class AtlasCodeDiffSelection
---@field path string
---@field old_path string|nil
---@field status string|nil
---@field group string|nil

---@class AtlasCodeDiffExplorer
---@field bufnr integer|nil
---@field winid integer|nil
---@field current_selection AtlasCodeDiffSelection|nil
---@field current_file_path string|nil
---@field status_result table<string, AtlasCodeDiffSelection[]>|nil
---@field on_file_select (fun(selection: AtlasCodeDiffSelection, opts: { no_jump: boolean }|nil))|nil

---@class AtlasCodeDiffLifecycle
---@field get_session fun(tabpage: integer): AtlasCodeDiffSession|nil
---@field get_explorer fun(tabpage: integer): AtlasCodeDiffExplorer|nil
---@field find_tabpage_by_buffer fun(buf: integer): integer|nil
---@field close fun(tabpage: integer): boolean

---@class AtlasCodeDiffReview
---@field tabpage integer
---@field lifecycle AtlasCodeDiffLifecycle
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
---@field pending_selection table|nil
---@field group integer
---@field generation integer
---@field closed boolean
---@field session_id string

---@class AtlasCodeDiffAttachOptions
---@field root string
---@field base_revision string
---@field head_revision string
---@field reload (fun(target: AtlasLoadingTarget|nil))|nil

---@param value string|nil
---@return string
local function clean_path(value)
	local path = tostring(value or "")
	path = path:gsub("\\", "/"):gsub("/+$", "")
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
	path = path:gsub("^%./", "")
	return path
end

---@param entry AtlasCodeDiffReview
---@param reason string|nil
---@return table
local function event_data(entry, reason)
	local data = {
		version = 1,
		session_id = entry.session_id,
		viewer = "codediff",
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

---@param buf integer
---@param path string
---@return string[]
local function buffer_lines(buf, path)
	if path == "" or not vim.api.nvim_buf_is_valid(buf) then
		return {}
	end
	return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param changes AtlasCodeDiffChange[]
---@param status DiffFileStatus
---@param old_line_count integer
---@param new_line_count integer
---@return AtlasDiffLineChange[]
local function line_changes(changes, status, old_line_count, new_line_count)
	local result = {}
	for _, change in ipairs(changes) do
		local old_count = math.max(0, change.original.end_line - change.original.start_line)
		local new_count = math.max(0, change.modified.end_line - change.modified.start_line)
		table.insert(result, {
			old_start = math.max(0, change.original.start_line - (old_count == 0 and 1 or 0)),
			old_count = old_count,
			new_start = math.max(0, change.modified.start_line - (new_count == 0 and 1 or 0)),
			new_count = new_count,
		})
	end
	if #result == 0 and status == "added" and new_line_count > 0 then
		table.insert(result, { old_start = 0, old_count = 0, new_start = 1, new_count = new_line_count })
	elseif #result == 0 and status == "deleted" and old_line_count > 0 then
		table.insert(result, { old_start = 1, old_count = old_line_count, new_start = 0, new_count = 0 })
	end
	return result
end

---@param entry AtlasCodeDiffReview
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
	if not entry.lifecycle.close(entry.tabpage) then
		vim.cmd("tabclose")
		return
	end
	M.detach(entry.tabpage, "reload")
	vim.schedule(function()
		callback(target)
	end)
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

---@param entry AtlasCodeDiffReview
---@param level "loading"|"success"|"warn"|"error"|"info"
---@param message string
---@param duration integer|nil
local function view_notify(entry, level, message, duration)
	statusline.notify(entry.statusline, level, message, duration)
end

---@param entry AtlasCodeDiffReview
---@param focus boolean
---@return boolean opened
local function open_review_panel(entry, focus)
	local panel = entry.review_panel
	local codediff = entry.lifecycle.get_session(entry.tabpage)
	local anchor = codediff and codediff.modified_win or nil
	if not anchor or not vim.api.nvim_win_is_valid(anchor) then
		anchor = codediff and codediff.original_win or nil
	end
	if not anchor then
		return false
	end
	local win = review_panel.open(panel, anchor, focus)
	if win then
		vim.api.nvim_set_option_value("statusline", STATUSLINE, { win = win, scope = "local" })
	end
	return win ~= nil
end

---@param entry AtlasCodeDiffReview
local function toggle_review_panel(entry)
	local panel = entry.review_panel
	if panel.win and vim.api.nvim_win_is_valid(panel.win) then
		review_panel.close(panel)
		return
	end
	open_review_panel(entry, true)
end

---@param entry AtlasCodeDiffReview
---@param path string
---@return AtlasCodeDiffSelection|nil
local function find_review_file(entry, path)
	path = relative_path(entry.root, path)
	local explorer = entry.lifecycle.get_explorer(entry.tabpage)
	if not explorer then
		return nil
	end
	local function matches(file)
		return relative_path(entry.root, file.path) == path or relative_path(entry.root, file.old_path) == path
	end
	if explorer.current_selection and matches(explorer.current_selection) then
		return vim.deepcopy(explorer.current_selection)
	end
	for _, group in ipairs({ "unstaged", "staged", "conflicts" }) do
		for _, file in ipairs((explorer.status_result or {})[group] or {}) do
			if matches(file) then
				file = vim.deepcopy(file)
				file.group = file.group or group
				return file
			end
		end
	end
	return nil
end

---@param entry AtlasCodeDiffReview
local function reveal_pending_selection(entry)
	local pending = entry.pending_selection
	local session = entry.session
	local document = session and session.document
	if
		not pending
		or not session
		or not document
		or (document.old.path ~= pending.path and document.new.path ~= pending.path)
	then
		return
	end
	entry.pending_selection = nil
	if pending.note and (document.binary or document.status == "deleted") then
		view_notify(entry, "info", "This note's file is no longer in the diff")
		return
	end
	local source = pending.side == "LEFT" and document.old.lines or document.new.lines
	if #source == 0 or pending.line < 1 then
		view_notify(entry, "info", "This review item's diff position is outdated")
		return
	end
	local line = math.min(pending.line, #source)
	local win = pending.side == "LEFT" and session.left.win or session.right.win
	if pending.side == "LEFT" and session.layout == "inline" then
		win = session.right.win
		line = position.opposite_line(document, "LEFT", line, vim.api.nvim_buf_line_count(session.right.buf))
	end
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	session.refresh_ui()
	vim.api.nvim_win_set_cursor(win, { line, 0 })
	vim.api.nvim_win_call(win, function()
		pcall(vim.cmd.normal, { "zvzz", bang = true })
	end)
	if vim.api.nvim_get_current_tabpage() == entry.tabpage then
		if pending.focus_diff then
			vim.api.nvim_set_current_win(win)
		else
			local panel = entry.review_panel
			if panel.win and vim.api.nvim_win_is_valid(panel.win) then
				vim.api.nvim_set_current_win(panel.win)
			end
		end
	end
end

---@param entry AtlasCodeDiffReview
---@param item AtlasReviewPanelSelection
---@param focus_diff boolean
local function select_review_item(entry, item, focus_diff)
	local session = entry.session
	if not session then
		return
	end
	local file, path, side, line
	if item.kind == "note" and item.note then
		path, side, line = item.note.file_path, "RIGHT", item.note.line
		file = find_review_file(entry, path)
	else
		local comment = item.comment
		local inline = comment and comment.inline or nil
		if not inline then
			view_notify(entry, "info", "This comment is not attached to the diff")
			return
		end
		path = inline.path
		side, line = position.location(inline)
		file = find_review_file(entry, path)
		if session.review then
			session.review.expanded_threads[review_threads.comment_key(comment)] = true
		end
	end
	if not file then
		view_notify(entry, "info", "This review item's file is no longer in the diff")
		return
	end
	if not side or type(line) ~= "number" then
		view_notify(entry, "info", "This review item no longer has a diff position")
		return
	end
	entry.pending_selection = {
		path = relative_path(entry.root, path),
		side = side,
		line = line,
		note = item.kind == "note",
		focus_diff = focus_diff,
	}
	local explorer = entry.lifecycle.get_explorer(entry.tabpage)
	if explorer and explorer.on_file_select then
		explorer.on_file_select(file, { no_jump = true })
	else
		entry.pending_selection = nil
	end
end

---@param entry AtlasCodeDiffReview
local function map_review(entry)
	local session = entry.session
	local actions = entry.actions
	if not session or not actions then
		return
	end
	local explorer = entry.lifecycle.get_explorer(entry.tabpage)
	local explorer_buf = explorer and explorer.bufnr
	local buffers = { session.left.buf, session.right.buf }
	if explorer_buf and vim.api.nvim_buf_is_valid(explorer_buf) then
		table.insert(buffers, explorer_buf)
	end
	review_keymaps.register(session, actions, {
		buffers = buffers,
		reload = entry.reload and function()
			reload(entry)
		end or nil,
	})
	review_panel.register_toggle(entry.review_panel, buffers)
end

---@param entry AtlasCodeDiffReview
---@param session AtlasReviewSession
local function refresh_scroll(entry, session)
	local scroll = require("codediff.ui.scroll")
	local current = vim.api.nvim_get_current_win()
	local current_is_diff = current == session.left.win or current == session.right.win
	local leader = current_is_diff and current or session.right.win or session.left.win
	scroll.refresh(entry.tabpage, leader)
	vim.cmd("redrawstatus")
end

---@param entry AtlasCodeDiffReview
---@return boolean
local function sync(entry)
	if entry.closed or not vim.api.nvim_tabpage_is_valid(entry.tabpage) then
		return false
	end
	---@type AtlasCodeDiffSession|nil
	local codediff = entry.lifecycle.get_session(entry.tabpage)
	if not codediff or not codediff.stored_diff_result then
		return false
	end
	local explorer = entry.lifecycle.get_explorer(entry.tabpage)
	if not explorer then
		return false
	end
	local root = entry.root
	local old_path = relative_path(root, codediff.original and codediff.original.relative)
	local new_path = relative_path(root, codediff.modified and codediff.modified.relative)
	local path = new_path ~= "" and new_path or old_path
	local selection = explorer.current_selection
	local selected_path = relative_path(root, selection and selection.path or explorer.current_file_path)
	local status = FILE_STATUSES[tostring(selection and selection.status or ""):sub(1, 1)] or "modified"
	if root == "" or path == "" then
		return false
	end
	if selected_path ~= "" and selected_path ~= old_path and selected_path ~= new_path then
		return false
	end
	if
		not codediff.original_bufnr
		or not codediff.modified_bufnr
		or not vim.api.nvim_buf_is_valid(codediff.original_bufnr)
		or not vim.api.nvim_buf_is_valid(codediff.modified_bufnr)
	then
		return false
	end
	local left_buf, left_win = codediff.original_bufnr, codediff.original_win
	local right_buf, right_win = codediff.modified_bufnr, codediff.modified_win
	local inline_deleted = status == "deleted"
		and codediff.layout == "inline"
		and right_win
		and vim.api.nvim_win_is_valid(right_win)
		and vim.api.nvim_win_get_buf(right_win) == left_buf
	if inline_deleted then
		left_win = right_win
		right_win = nil
	elseif right_win and vim.api.nvim_win_is_valid(right_win) and vim.api.nvim_win_get_buf(right_win) ~= right_buf then
		return false
	elseif
		left_win
		and left_win ~= right_win
		and vim.api.nvim_win_is_valid(left_win)
		and vim.api.nvim_win_get_buf(left_win) ~= left_buf
	then
		return false
	end

	local old_lines = buffer_lines(left_buf, old_path)
	local new_lines = status == "deleted" and {} or buffer_lines(right_buf, new_path)
	local changes = line_changes(codediff.stored_diff_result.changes or {}, status, #old_lines, #new_lines)
	local previous = entry.session
	local buffers_changed = not previous or previous.left.buf ~= left_buf or previous.right.buf ~= right_buf
	if previous and buffers_changed then
		comment_renderer.clear_comments(previous.left.buf)
		comment_renderer.clear_comments(previous.right.buf)
		notes.clear(previous)
	end
	local context = entry.context
	local session = previous or { tabpage = entry.tabpage, closing = false }
	session.head_revision = entry.head_revision
	session.layout = codediff.layout == "inline" and not inline_deleted and "inline" or "side-by-side"
	session.left = { buf = left_buf, win = left_win }
	session.right = { buf = right_buf, win = right_win }
	session.document = {
		status = status,
		old = { path = old_path ~= "" and old_path or path, lines = old_lines },
		new = { path = new_path ~= "" and new_path or path, lines = new_lines },
		changes = changes,
		binary = false,
	}
	entry.session = session
	if left_win and vim.api.nvim_win_is_valid(left_win) then
		vim.api.nvim_set_option_value("statusline", STATUSLINE, { win = left_win, scope = "local" })
	end
	if right_win and vim.api.nvim_win_is_valid(right_win) then
		vim.api.nvim_set_option_value("statusline", STATUSLINE, { win = right_win, scope = "local" })
	end
	if explorer.winid and vim.api.nvim_win_is_valid(explorer.winid) then
		vim.api.nvim_set_option_value("statusline", STATUSLINE, { win = explorer.winid, scope = "local" })
	end
	vim.cmd("redrawstatus")
	session.refresh_ui = function()
		comments.render(session)
		notes.render(session)
		review_panel.render(entry.review_panel, review_panel_data(session))
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
		notes.attach(session, context)
		local ok, err = pcall(comments.attach, session, context)
		if not ok then
			comments.detach(session)
			view_notify(entry, "error", "Unable to load comments: " .. tostring(err))
		else
			events.emit("AtlasReviewAttached", event_data(entry))
		end
	else
		if buffers_changed then
			map_review(entry)
		end
		session.refresh_ui()
	end
	if entry.auto_open_panel and open_review_panel(entry, false) then
		entry.auto_open_panel = false
	end
	reveal_pending_selection(entry)
	return true
end

---@param entry AtlasCodeDiffReview
local function wait_until_ready(entry)
	entry.generation = entry.generation + 1
	local generation = entry.generation
	local attempt = 0
	local function check()
		if entry.closed or entry.generation ~= generation then
			return
		end
		if sync(entry) then
			return
		end
		attempt = attempt + 1
		if attempt < READY_RETRIES then
			vim.defer_fn(check, 25)
		end
	end
	vim.schedule(check)
end

---@param entry AtlasCodeDiffReview
local function register_events(entry)
	vim.api.nvim_create_autocmd("User", {
		group = entry.group,
		pattern = "CodeDiffFileSelect",
		callback = function(args)
			if args.data and args.data.tabpage == entry.tabpage then
				wait_until_ready(entry)
			end
		end,
	})
	vim.api.nvim_create_autocmd("User", {
		group = entry.group,
		pattern = "CodeDiffVirtualFileLoaded",
		callback = function(args)
			local buf = args.data and args.data.buf
			if buf and entry.lifecycle.find_tabpage_by_buffer(buf) == entry.tabpage then
				wait_until_ready(entry)
			end
		end,
	})
	vim.api.nvim_create_autocmd("User", {
		group = entry.group,
		pattern = "CodeDiffClose",
		callback = function(args)
			if args.data and args.data.tabpage == entry.tabpage then
				vim.schedule(function()
					M.detach(entry.tabpage, "viewer_closed")
				end)
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = entry.group,
		callback = function(args)
			local panel = entry.review_panel
			if tonumber(args.match) == panel.win then
				panel.win = nil
			end
		end,
	})
end

---@param context AtlasPreparedReviewContext
---@param tabpage integer|nil
---@param opts AtlasCodeDiffAttachOptions
---@return string|nil err
function M.attach(context, tabpage, opts)
	local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
	if not ok then
		return "CodeDiff lifecycle is unavailable"
	end
	tabpage = tabpage or vim.api.nvim_get_current_tabpage()
	if not lifecycle.get_session(tabpage) then
		return "CodeDiff session is unavailable"
	end
	M.detach(tabpage, "replaced")
	local diff_config = (require("atlas.config").options.pulls or {}).diff or {}
	---@type AtlasCodeDiffReview
	local entry
	entry = {
		tabpage = tabpage,
		lifecycle = lifecycle,
		context = context,
		root = clean_path(opts.root),
		base_revision = opts.base_revision,
		head_revision = opts.head_revision,
		reload = opts.reload,
		session = nil,
		actions = nil,
		review_panel = review_panel.create(string.format("atlas-codediff://%d/review", tabpage), {
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
		pending_selection = nil,
		group = vim.api.nvim_create_augroup("AtlasCodeDiffReview" .. tabpage, { clear = true }),
		generation = 0,
		closed = false,
		session_id = events.new_id("codediff"),
	}
	review_panel.register_keymaps(entry.review_panel)
	review_panel.register_toggle(entry.review_panel, { entry.review_panel.buf })
	review_panel.render(entry.review_panel, {
		comments = context.initial_review.comments,
		tasks = context.initial_review.tasks,
		notes = {},
		note_target = nil,
	})
	sessions[tabpage] = entry
	register_events(entry)
	local codediff = lifecycle.get_session(tabpage)
	local explorer = lifecycle.get_explorer(tabpage)
	local buffers = {}
	for _, buf in pairs({ codediff.original_bufnr, codediff.modified_bufnr, explorer and explorer.bufnr }) do
		if buf and vim.api.nvim_buf_is_valid(buf) then
			table.insert(buffers, buf)
		end
	end
	review_panel.register_toggle(entry.review_panel, buffers)
	if entry.auto_open_panel and open_review_panel(entry, false) then
		entry.auto_open_panel = false
	end
	wait_until_ready(entry)
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
	entry.generation = entry.generation + 1
	entry.pending_selection = nil
	local attached = entry.session and entry.session.review ~= nil
	if entry.session then
		entry.session.closing = true
		comments.detach(entry.session)
		notes.detach(entry.session)
	end
	statusline.dispose(entry.statusline)
	review_panel.delete(entry.review_panel)
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
		nil,
		nil,
		session.review,
		session.notes,
		entry.statusline
	)
end

return M
