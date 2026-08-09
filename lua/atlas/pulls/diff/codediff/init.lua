local M = {}

local comments = require("atlas.pulls.diff.shared.comments")
local events = require("atlas.core.events")
local notes = require("atlas.pulls.diff.shared.notes")
local notify = require("atlas.core.notify")
local comment_renderer = require("atlas.pulls.diff.shared.ui.comment_renderer")
local review_keymaps = require("atlas.pulls.diff.shared.keymaps")
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
---@field status string|nil

---@class AtlasCodeDiffExplorer
---@field bufnr integer|nil
---@field winid integer|nil
---@field current_selection AtlasCodeDiffSelection|nil
---@field current_file_path string|nil

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
		refresh_scroll(entry, session)
	end
	session.review_view = {
		notify = function(level, message)
			local notify_level = level == "error" and vim.log.levels.ERROR
				or level == "warn" and vim.log.levels.WARN
				or vim.log.levels.INFO
			notify.show(notify_level, message)
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
			notify.error("Unable to load comments: " .. tostring(err))
		else
			events.emit("AtlasReviewAttached", event_data(entry))
		end
	else
		if buffers_changed then
			map_review(entry)
		end
		session.refresh_ui()
	end
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
	---@type AtlasCodeDiffReview
	local entry = {
		tabpage = tabpage,
		lifecycle = lifecycle,
		context = context,
		root = clean_path(opts.root),
		base_revision = opts.base_revision,
		head_revision = opts.head_revision,
		reload = opts.reload,
		session = nil,
		actions = nil,
		group = vim.api.nvim_create_augroup("AtlasCodeDiffReview" .. tabpage, { clear = true }),
		generation = 0,
		closed = false,
		session_id = events.new_id("codediff"),
	}
	sessions[tabpage] = entry
	register_events(entry)
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
		nil,
		nil,
		session.review,
		session.notes
	)
end

return M
