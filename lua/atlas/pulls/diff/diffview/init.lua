local M = {}

local comments = require("atlas.pulls.diff.shared.comments")
local events = require("atlas.core.events")
local notes = require("atlas.pulls.diff.shared.notes")
local notify = require("atlas.core.notify")
local comment_renderer = require("atlas.pulls.diff.shared.ui.comment_renderer")
local review_keymaps = require("atlas.pulls.diff.shared.keymaps")
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
		notify.error("Unable to close Diffview: " .. tostring(err))
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
end

---@param entry AtlasDiffviewReview
---@param session AtlasReviewSession
local function refresh_scroll(entry, session)
	comments.render(session)
	notes.render(session)
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
		notify.warn("Atlas review overlays require a two-pane Diffview layout")
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
		notes.attach(session, entry.context)
		local ok, err = pcall(comments.attach, session, entry.context)
		if not ok then
			comments.detach(session)
			notify.error("Unable to load comments: " .. tostring(err))
		else
			events.emit("AtlasReviewAttached", event_data(entry))
		end
	else
		if buffers_changed or resumed then
			map_review(entry)
		end
		session.refresh_ui()
	end
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
	---@type AtlasDiffviewReview
	local entry = {
		tabpage = tabpage,
		view = view,
		context = context,
		root = clean_path(opts.root),
		base_revision = opts.base_revision,
		head_revision = opts.head_revision,
		reload = opts.reload,
		session = nil,
		actions = nil,
		group = vim.api.nvim_create_augroup("AtlasDiffviewReview" .. tabpage, { clear = true }),
		sync_scheduled = false,
		suspended = false,
		closed = false,
		session_id = events.new_id("diffview"),
		additions = 0,
		deletions = 0,
	}
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
		session.notes
	)
end

return M
