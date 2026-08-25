local M = {}

local config = require("atlas.config")
local keymaps = require("atlas.core.keymaps")
local core_notify = require("atlas.core.notify")
local comments = require("atlas.pulls.diff.comments")
local position = require("atlas.pulls.diff.position")
local review_keymaps = require("atlas.pulls.diff.keymaps")
local review_panel = require("atlas.pulls.diff.ui.review_panel")
local session_api = require("atlas.pulls.diff.session")

local READY_RETRIES = 80

---@type table<string, DiffFileStatus>
local FILE_STATUSES = {
	A = "added",
	D = "deleted",
	M = "modified",
	R = "renamed",
	T = "type_changed",
}

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
---@field tree table|nil
---@field on_file_select (fun(selection: AtlasCodeDiffSelection, opts: { no_jump: boolean }|nil))|nil

---@class AtlasCodeDiffLifecycle
---@field get_session fun(tabpage: integer): AtlasCodeDiffSession|nil
---@field get_explorer fun(tabpage: integer): AtlasCodeDiffExplorer|nil
---@field close fun(tabpage: integer): boolean

---@class AtlasCodeDiffState
---@field lifecycle AtlasCodeDiffLifecycle
---@field tabpage integer
---@field pending_selection table|nil
---@field group integer
---@field generation integer
---@field auto_open_panel boolean
---@field closed boolean
---@field reloading boolean
---@field reload_view (fun())|nil

---@param value string|nil
---@return string
local function clean_path(value)
	local path = tostring(value or "")
	return (path:gsub("\\", "/"):gsub("/+$", ""))
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
	return (path:gsub("^%./", ""))
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
		result[#result + 1] = {
			old_start = math.max(0, change.original.start_line - (old_count == 0 and 1 or 0)),
			old_count = old_count,
			new_start = math.max(0, change.modified.start_line - (new_count == 0 and 1 or 0)),
			new_count = new_count,
		}
	end
	if #result == 0 and status == "added" and new_line_count > 0 then
		result[#result + 1] = { old_start = 0, old_count = 0, new_start = 1, new_count = new_line_count }
	elseif #result == 0 and status == "deleted" and old_line_count > 0 then
		result[#result + 1] = { old_start = 1, old_count = old_line_count, new_start = 0, new_count = 0 }
	end
	return result
end

---@param session AtlasDiffSession
---@param level "loading"|"success"|"warn"|"error"|"info"
---@param message string
---@param duration integer|nil
local function notify(session, level, message, duration)
	session_api.notify(session, level, message, duration)
end

---@param session AtlasDiffSession
---@param focus boolean
---@return boolean
local function open_review_panel(session, focus)
	local state = session.viewer_state --[[@as AtlasCodeDiffState]]
	local panel = session.review_panel
	if not panel or state.closed then
		return false
	end
	local codediff = state.lifecycle.get_session(state.tabpage)
	local anchor = codediff and codediff.modified_win or nil
	if not anchor or not vim.api.nvim_win_is_valid(anchor) then
		anchor = codediff and codediff.original_win or nil
	end
	if not anchor then
		return false
	end
	local win = review_panel.open(panel, anchor, focus)
	if win then
		session.statusline:attach(win)
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
---@param path string
---@return AtlasCodeDiffSelection|nil
local function find_review_file(session, path)
	local state = session.viewer_state --[[@as AtlasCodeDiffState]]
	path = relative_path(session.source.root, path)
	local explorer = state.lifecycle.get_explorer(state.tabpage)
	if not explorer then
		return nil
	end
	local function matches(file)
		return relative_path(session.source.root, file.path) == path
			or relative_path(session.source.root, file.old_path) == path
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

---@param session AtlasDiffSession
local function reveal_pending_selection(session)
	local state = session.viewer_state --[[@as AtlasCodeDiffState]]
	local pending = state.pending_selection
	local current = session.current
	local document = current and current.document
	if
		not pending
		or not current
		or not document
		or (document.old.path ~= pending.path and document.new.path ~= pending.path)
	then
		return
	end
	state.pending_selection = nil
	if pending.note and (document.binary or document.status == "deleted") then
		notify(session, "info", "This note's file is no longer in the diff")
		return
	end
	if pending.comment then
		pending.side, pending.line = position.comment(document, pending.comment)
	end
	if not pending.side or not pending.line then
		notify(session, "info", "This review item no longer has a diff position")
		return
	end
	local source = pending.side == "LEFT" and document.old.lines or document.new.lines
	if (not pending.comment or not pending.comment.file) and (#source == 0 or pending.line < 1) then
		notify(session, "info", "This review item's diff position is outdated")
		return
	end
	local win = pending.side == "LEFT" and current.left.win or current.right.win
	if pending.side == "LEFT" and current.layout == "inline" then
		win = current.right.win
		pending.line =
			position.opposite_line(document, "LEFT", pending.line, vim.api.nvim_buf_line_count(current.right.buf))
	end
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	local line = math.min(pending.line, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)))
	vim.api.nvim_win_set_cursor(win, { line, 0 })
	vim.api.nvim_win_call(win, function()
		pcall(vim.cmd.normal, { args = { "zv" }, bang = true })
	end)
	if vim.api.nvim_get_current_tabpage() == state.tabpage then
		if pending.focus_diff then
			vim.api.nvim_set_current_win(win)
		else
			local panel = session.review_panel
			if panel and panel.win and vim.api.nvim_win_is_valid(panel.win) then
				vim.api.nvim_set_current_win(panel.win)
			end
		end
	end
end

---@param session AtlasDiffSession
---@param item AtlasDiffReviewPanelSelection
---@param focus_diff boolean
local function focus_item(session, item, focus_diff)
	local state = session.viewer_state --[[@as AtlasCodeDiffState]]
	if state.closed or not session.current then
		return
	end
	local note = item.kind == "note" and item.note or nil
	local comment = item.comment
	local target = comment and (comment.file or comment.inline) or nil
	if not note and not target then
		notify(session, "info", "This comment is not attached to the diff")
		return
	end
	local path = note and note.file_path or target.path
	local side = note and "RIGHT" or nil
	local line = note and note.line or nil
	if comment and comment.inline then
		side, line = position.location(comment.inline)
	end
	local file = find_review_file(session, path)
	if not file then
		notify(session, "info", "This review item's file is no longer in the diff")
		return
	end
	if (not comment or not comment.file) and (not side or type(line) ~= "number") then
		notify(session, "info", "This review item no longer has a diff position")
		return
	end
	state.pending_selection = {
		path = relative_path(session.source.root, path),
		side = side,
		line = line,
		note = item.kind == "note",
		comment = comment,
		focus_diff = focus_diff,
	}
	local explorer = state.lifecycle.get_explorer(state.tabpage)
	if explorer and explorer.on_file_select then
		explorer.on_file_select(file, { no_jump = true })
	else
		state.pending_selection = nil
	end
end

---@param session AtlasDiffSession
local function refresh_view(session)
	local state = session.viewer_state --[[@as AtlasCodeDiffState]]
	local current = session.current
	if state.closed or not current then
		return
	end
	local active_win = vim.api.nvim_get_current_win()
	local diff_win = active_win == current.left.win or active_win == current.right.win
	local leader = diff_win and active_win or current.right.win or current.left.win
	if leader then
		require("codediff.ui.scroll").refresh(state.tabpage, leader)
	end
end

---@param session AtlasDiffSession
---@param buffers integer[]
local function register_review_buffers(session, buffers)
	local state = session.viewer_state --[[@as AtlasCodeDiffState]]
	local valid, seen = {}, {}
	for _, buf in ipairs(buffers) do
		if buf and not seen[buf] and vim.api.nvim_buf_is_valid(buf) then
			seen[buf] = true
			valid[#valid + 1] = buf
		end
	end
	review_keymaps.register(session, {
		buffers = valid,
		reload = state.reload_view,
		help_key = keymaps.resolve("pulls.external_help"),
		file_buffers = { state.lifecycle.get_explorer(state.tabpage).bufnr },
		add_file_comment = function(pending)
			local explorer = state.lifecycle.get_explorer(state.tabpage)
			local node = explorer and explorer.tree and explorer.tree:get_node() or nil
			local file = node and node.data or nil
			if file and file.type ~= "group" and file.type ~= "directory" then
				comments.add_to_file(session, {
					path = relative_path(session.source.root, file.path),
					old_path = file.old_path and relative_path(session.source.root, file.old_path) or nil,
				}, pending)
			end
		end,
	})
	if session.review_panel then
		review_panel.register_toggle(session.review_panel, valid)
	end
end

---@param session AtlasDiffSession
---@return boolean
local function sync(session)
	local state = session.viewer_state --[[@as AtlasCodeDiffState]]
	if
		state.closed
		or session.closed
		or not vim.api.nvim_tabpage_is_valid(state.tabpage)
		or session_api.get(state.tabpage) ~= session
	then
		return false
	end
	local codediff = state.lifecycle.get_session(state.tabpage)
	if not codediff or not codediff.stored_diff_result then
		return false
	end
	local explorer = state.lifecycle.get_explorer(state.tabpage)
	if not explorer then
		return false
	end

	local old_path = relative_path(session.source.root, codediff.original and codediff.original.relative)
	local new_path = relative_path(session.source.root, codediff.modified and codediff.modified.relative)
	local path = new_path ~= "" and new_path or old_path
	local selection = explorer.current_selection
	local selected_path = relative_path(session.source.root, selection and selection.path or explorer.current_file_path)
	local status = FILE_STATUSES[tostring(selection and selection.status or ""):sub(1, 1)] or "modified"
	if session.source.root == "" or path == "" then
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
	local previous = session.current
	local buffers_changed = not previous or previous.left.buf ~= left_buf or previous.right.buf ~= right_buf
	local current = {
		layout = codediff.layout == "inline" and not inline_deleted and "inline" or "side-by-side",
		left = { buf = left_buf, win = left_win },
		right = { buf = right_buf, win = right_win },
		document = {
			status = status,
			old = { path = old_path ~= "" and old_path or path, lines = old_lines },
			new = { path = new_path ~= "" and new_path or path, lines = new_lines },
			changes = line_changes(codediff.stored_diff_result.changes or {}, status, #old_lines, #new_lines),
			binary = false,
		},
	}

	session.statusline:attach(left_win)
	session.statusline:attach(right_win)
	session.statusline:attach(explorer.winid)
	session_api.set_current(session, current)
	session_api.review_attached(session)
	if buffers_changed then
		register_review_buffers(session, { left_buf, right_buf, explorer.bufnr })
	end
	if state.auto_open_panel and open_review_panel(session, false) then
		state.auto_open_panel = false
	end
	reveal_pending_selection(session)
	return true
end

---@param session AtlasDiffSession
local function wait_until_ready(session)
	local state = session.viewer_state --[[@as AtlasCodeDiffState]]
	state.generation = state.generation + 1
	local generation = state.generation
	local function check(attempt)
		if session.viewer_state ~= state or state.closed or state.generation ~= generation then
			return
		end
		if sync(session) or attempt >= READY_RETRIES then
			return
		end
		vim.defer_fn(function()
			check(attempt + 1)
		end, 25)
	end
	vim.schedule(function()
		check(1)
	end)
end

---@param session AtlasDiffSession
---@param state AtlasCodeDiffState
local function register_events(session, state)
	vim.api.nvim_create_autocmd("User", {
		group = state.group,
		pattern = "CodeDiffFileSelect",
		callback = function(args)
			if session.viewer_state == state and args.data and args.data.tabpage == state.tabpage then
				-- CodeDiff rebuilds its buffers after this event.
				vim.schedule(function()
					if session.viewer_state == state and not state.closed then
						wait_until_ready(session)
					end
				end)
			end
		end,
	})
	vim.api.nvim_create_autocmd("User", {
		group = state.group,
		pattern = "CodeDiffVirtualFileLoaded",
		callback = function(args)
			local buf = args.data and args.data.buf
			if session.viewer_state == state and buf then
				wait_until_ready(session)
			end
		end,
	})
	vim.api.nvim_create_autocmd("User", {
		group = state.group,
		pattern = "CodeDiffClose",
		callback = function(args)
			if not args.data or args.data.tabpage ~= state.tabpage then
				return
			end
			vim.schedule(function()
				if session.viewer_state == state and not state.reloading and not state.closed then
					M.detach(session, "viewer_closed")
				end
			end)
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = state.group,
		callback = function(args)
			local panel = session.review_panel
			if session.viewer_state == state and panel and tonumber(args.match) == panel.win then
				panel.win = nil
			end
		end,
	})
end

---@param session AtlasDiffSession
local function reload_view(session)
	local state = session.viewer_state --[[@as AtlasCodeDiffState]]
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
		winbar = vim.wo[win].winbar,
	}
	state.reloading = true
	if not state.lifecycle.close(state.tabpage) then
		state.reloading = false
		vim.cmd("tabclose")
		return
	end
	M.detach(session, "reload")
	vim.schedule(function()
		reload(target)
	end)
end

---@param session AtlasDiffSession
---@param lifecycle AtlasCodeDiffLifecycle
---@param tabpage integer
local function attach(session, lifecycle, tabpage)
	local diff_config = (config.options.pulls or {}).diff or {}
	---@type AtlasCodeDiffState
	local state = {
		lifecycle = lifecycle,
		tabpage = tabpage,
		pending_selection = nil,
		group = vim.api.nvim_create_augroup("AtlasCodeDiff" .. session.id, { clear = true }),
		generation = 0,
		auto_open_panel = diff_config.show_review_panel == true
			and (session.review ~= nil or session.note_target ~= nil),
		closed = false,
		reloading = false,
	}
	session.viewer_state = state
	state.reload_view = function()
		reload_view(session)
	end
	session_api.attach(session, {
		tabpage = tabpage,
		notify = function(level, message, duration)
			core_notify.show(level, message, { timeout = duration })
		end,
		focus_item = function(item, focus_diff)
			focus_item(session, item, focus_diff)
		end,
		render_view = function()
			refresh_view(session)
		end,
		toggle_review_panel = function(focus)
			toggle_review_panel(session, focus)
		end,
	})

	local panel
	if session.review or session.note_target then
		panel = session_api.create_review_panel(session, string.format("atlas-diff-codediff://%d/review", tabpage))
		review_panel.configure(panel)
		review_panel.register_keymaps(panel)
	end
	register_events(session, state)

	local codediff = lifecycle.get_session(tabpage)
	local explorer = lifecycle.get_explorer(tabpage)
	for _, win in pairs({
		codediff and codediff.original_win,
		codediff and codediff.modified_win,
		explorer and explorer.winid,
	}) do
		session.statusline:attach(win)
	end
	local buffers = panel and { panel.buf } or {}
	for _, buf in pairs({
		codediff and codediff.original_bufnr,
		codediff and codediff.modified_bufnr,
		explorer and explorer.bufnr,
	}) do
		if buf and vim.api.nvim_buf_is_valid(buf) then
			buffers[#buffers + 1] = buf
		end
	end
	if panel then
		review_panel.register_toggle(panel, buffers)
	end
	if panel and state.auto_open_panel and open_review_panel(session, false) then
		state.auto_open_panel = false
	end
	wait_until_ready(session)
end

---@param session AtlasDiffSession
---@param loading_view AtlasLoadingView
---@param on_done fun(err: string|nil)
---@return { cancel: fun() }
function M.open(session, loading_view, on_done)
	local finished = false
	local cancelled = false
	local opened_tabpage
	local autocmd_id

	local function finish(err)
		if finished then
			return
		end
		finished = true
		if autocmd_id then
			pcall(vim.api.nvim_del_autocmd, autocmd_id)
			autocmd_id = nil
		end
		if cancelled then
			return
		end
		loading_view:finish()
		on_done(err)
	end

	autocmd_id = vim.api.nvim_create_autocmd("User", {
		pattern = "CodeDiffOpen",
		callback = function(args)
			local tabpage = args.data and args.data.tabpage
			if not tabpage then
				return
			end
			local loaded, lifecycle = pcall(require, "codediff.ui.lifecycle")
			local codediff = loaded and lifecycle.get_session(tabpage) or nil
			if not codediff then
				return
			end
			opened_tabpage = tabpage
			if cancelled then
				pcall(lifecycle.close, tabpage)
				finish(nil)
				return
			end
			local ok, err = pcall(attach, session, lifecycle, tabpage)
			if not ok then
				local state = session.viewer_state --[[@as AtlasCodeDiffState]]
				if state.lifecycle == lifecycle and state.tabpage == tabpage then
					M.detach(session, "attach_failed")
				end
			end
			vim.schedule(function()
				if ok then
					finish(nil)
				else
					finish("Unable to attach review to CodeDiff: " .. tostring(err))
				end
			end)
		end,
	})

	local source = session.source
	local args = { "--repo", source.root }
	if source.head_revision then
		args[#args + 1] = source.base_revision .. "..." .. source.head_revision
	end
	local ok, err = pcall(vim.api.nvim_win_call, loading_view.win, function()
		vim.api.nvim_cmd({ cmd = "CodeDiff", args = args }, {})
	end)
	if not ok then
		finish(tostring(err))
	end
	vim.defer_fn(function()
		if not finished then
			finish("CodeDiff did not open; check CodeDiff notifications for details")
		end
	end, 15000)

	return {
		cancel = function()
			if finished or cancelled then
				return
			end
			cancelled = true
			if opened_tabpage then
				local loaded, lifecycle = pcall(require, "codediff.ui.lifecycle")
				if loaded then
					pcall(lifecycle.close, opened_tabpage)
				end
				finish(nil)
			end
		end,
	}
end

---@param session AtlasDiffSession
---@param reason string|nil
function M.detach(session, reason)
	local state = session.viewer_state --[[@as AtlasCodeDiffState]]
	if session.closed or not state or state.closed then
		return
	end
	state.closed = true
	state.generation = state.generation + 1
	state.pending_selection = nil
	pcall(vim.api.nvim_del_augroup_by_id, state.group)
	session_api.detach(session, reason)
end

return M
