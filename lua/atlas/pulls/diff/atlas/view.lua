local M = {}

local commits = require("atlas.pulls.diff.atlas.commits")
local diff = require("atlas.ui.components.diff_hunks")
local explorer = require("atlas.pulls.diff.atlas.explorer")
local renderer = require("atlas.pulls.diff.atlas.renderer")
local review_panel = require("atlas.pulls.diff.ui.review_panel")
local session_api = require("atlas.pulls.diff.session")
local statusline = require("atlas.pulls.diff.ui.statusline")

---@class AtlasNativeDiffOptions
---@field layout AtlasDiffLayout
---@field compact boolean
---@field compact_context_lines integer
---@field show_review_panel boolean
---@field explorer AtlasNativeDiffExplorerOptions

---@class AtlasNativeDiffState
---@field tabpage integer
---@field range AtlasNativeDiffRange
---@field files DiffFile[]
---@field document AtlasDiffDocument
---@field selected_index integer
---@field pending_index integer|nil
---@field layout AtlasDiffLayout
---@field preferred_layout AtlasDiffLayout
---@field compact boolean
---@field compact_context_lines integer
---@field number boolean
---@field relativenumber boolean
---@field explorer AtlasNativeDiffExplorerOptions
---@field collapsed_folders table<string, boolean>
---@field panel_items table<integer, AtlasNativeDiffPanelItem>
---@field panel AtlasDiffWindow
---@field commits_panel AtlasDiffWindow
---@field commits_visible boolean
---@field commit_items table<integer, PullsCommit>
---@field left AtlasDiffWindow
---@field right AtlasDiffWindow
---@field annotated_paths table<string, { comments: boolean, notes: boolean }>
---@field inline_deleted_lines boolean
---@field additions integer
---@field deletions integer
---@field job { cancel: fun() }|nil
---@field group integer|nil
---@field closing boolean
---@field lifecycle AtlasDiffLifecycle

---@param name string|nil
---@param buftype "nofile"|"nowrite"|nil
---@return integer
local function create_buffer(name, buftype)
	local buf = vim.api.nvim_create_buf(false, true)
	if name then
		vim.api.nvim_buf_set_name(buf, name)
	end
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].buflisted = false
	vim.bo[buf].buftype = buftype or "nofile"
	vim.bo[buf].swapfile = false
	vim.bo[buf].undolevels = -1
	vim.bo[buf].readonly = buftype == "nowrite"
	return buf
end

---@param anchor integer
---@param buf integer
---@param direction "left"|"right"|"above"|"below"
---@param size integer|nil
---@return integer
local function split_window(anchor, buf, direction, size)
	---@type vim.api.keyset.win_config
	local config = { split = direction, win = anchor }
	if direction == "left" or direction == "right" then
		config.width = size
	else
		config.height = size
	end
	return vim.api.nvim_open_win(buf, false, config)
end

---@param name string
---@param current integer
---@return integer|nil
local function find_named_buffer(name, current)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if buf ~= current and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == name then
			return buf
		end
	end
	return nil
end

---@param buf integer
---@param path string
local function set_filetype(buf, path)
	local filetype = path ~= "" and (vim.filetype.match({ filename = path }) or "") or ""
	if vim.bo[buf].filetype == filetype then
		return
	end
	pcall(vim.treesitter.stop, buf)
	if filetype ~= "" then
		pcall(vim.treesitter.start, buf, vim.treesitter.language.get_lang(filetype) or filetype)
	end
	vim.bo[buf].filetype = filetype
end

---@param buf integer
---@param lines string[]
---@param path string
local function set_buffer(buf, lines, path)
	vim.bo[buf].readonly = false
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	set_filetype(buf, path)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	vim.bo[buf].readonly = true
end

---@param state AtlasNativeDiffState
---@return integer|nil
local function content_window(state)
	return state.right.win or state.left.win
end

---@param session AtlasDiffSession
local function arrange_content_windows(session)
	local state = session.viewer_state --[[@as AtlasNativeDiffState]]
	local primary = content_window(state)
	if not primary then
		return
	end

	local single_sided = state.document.status == "added" or state.document.status == "deleted"
	state.layout = single_sided and "side-by-side" or state.preferred_layout
	if state.layout == "side-by-side" and not single_sided then
		if not state.right.win then
			state.right.win = primary
			state.left.win = nil
		end
		vim.api.nvim_win_set_buf(state.right.win, state.right.buf)
		if not state.left.win then
			state.left.win = split_window(state.right.win, state.left.buf, "left", nil)
		else
			vim.api.nvim_win_set_buf(state.left.win, state.left.buf)
		end
		return
	end

	if state.left.win and state.right.win then
		local left = state.left.win
		state.left.win = nil
		if vim.api.nvim_get_current_win() == left then
			vim.api.nvim_set_current_win(state.right.win)
		end
		vim.api.nvim_win_close(left, true)
	end

	primary = content_window(state)
	if state.document.status == "deleted" then
		state.left.win = primary
		state.right.win = nil
		vim.api.nvim_win_set_buf(primary, state.left.buf)
	else
		state.left.win = nil
		state.right.win = primary
		vim.api.nvim_win_set_buf(primary, state.right.buf)
	end
end

---@param session AtlasDiffSession
---@param buf integer
---@param revision string
---@param path string
local function name_content_buffer(session, buf, revision, path)
	local root = vim.fn.fnamemodify(session.source.root, ":p"):gsub("[\\/]$", ""):gsub("\\", "/"):gsub("^/", "")
	local relative_path = path:gsub("^[/\\]+", "")
	local prefix = string.format("atlas-diff:///%s///%s/", root, revision)
	local name = prefix .. relative_path
	local duplicate = 0
	while find_named_buffer(name, buf) do
		duplicate = duplicate + 1
		name =
			string.format("%s.atlas-session-%d-%d/%s", prefix, session.viewer_state.tabpage, duplicate, relative_path)
	end
	vim.api.nvim_buf_set_name(buf, name)
	vim.bo[buf].buflisted = true
end

---@param session AtlasDiffSession
---@param win integer
function M.configure_content_window(session, win)
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	local state = session.viewer_state
	local side_by_side = state.layout == "side-by-side" and state.left.win ~= nil and state.right.win ~= nil
	local options = vim.wo[win][0]
	options.colorcolumn = ""
	options.cursorbind = false
	options.cursorcolumn = false
	options.cursorline = false
	options.foldenable = state.compact and not state.document.binary and #state.document.changes > 0
	options.foldcolumn = "0"
	options.foldmethod = "manual"
	options.list = false
	options.number = state.number
	options.relativenumber = state.relativenumber
	options.spell = false
	options.diff = side_by_side
	options.scrollbind = side_by_side
	options.wrap = false
	options.winhighlight = ""

	local file = state.files[state.selected_index]
	local path = vim.api.nvim_win_get_buf(win) == state.left.buf and state.document.old.path or state.document.new.path
	local additions, deletions = diff.file_stats(file)
	local marker = file.status == "unknown" and "?" or file.status:sub(1, 1):upper()
	local marker_hl = file.status == "added" and "AtlasTextPositive"
		or file.status == "deleted" and "AtlasLogError"
		or file.status == "renamed" and "AtlasLogInfo"
		or file.status == "unknown" and "AtlasTextMuted"
		or "AtlasTextWarning"
	options.winbar = string.format(
		"%%#Normal# %s %%=%%#AtlasTextPositive#+%d %%#AtlasLogError#-%d %%#%s#%s ",
		path:gsub("%%", "%%%%"),
		additions,
		deletions,
		marker_hl,
		marker
	)
	statusline.attach(win)
end

---@param session AtlasDiffSession
function M.render_document(session)
	local state = session.viewer_state
	local current = M.current(session)
	renderer.file(state.document, {
		layout = current.layout,
		compact = state.compact,
		compact_context_lines = state.compact_context_lines,
		left = current.left,
		right = current.right,
	})
	if current.layout == "side-by-side" and current.left.win and current.right.win then
		vim.api.nvim_win_call(current.right.win, function()
			vim.cmd("syncbind")
		end)
	end
end

---@param session AtlasDiffSession
local function focus_first_hunk(session)
	local state = session.viewer_state
	local first = state.document.changes[1]
	if state.right.win and vim.api.nvim_win_is_valid(state.right.win) then
		local line = first and math.max(1, math.min(#state.document.new.lines, first.new_start)) or 1
		vim.api.nvim_win_set_cursor(state.right.win, { line, 0 })
	end
	if state.left.win and vim.api.nvim_win_is_valid(state.left.win) then
		local line = first and math.max(1, math.min(#state.document.old.lines, first.old_start)) or 1
		vim.api.nvim_win_set_cursor(state.left.win, { line, 0 })
	end
end

---@param session AtlasDiffSession
---@param document AtlasDiffDocument
function M.set_document(session, document)
	local state = session.viewer_state
	state.document = document
	name_content_buffer(session, state.left.buf, session.source.base_revision, document.old.path)
	name_content_buffer(session, state.right.buf, session.source.head_revision or "WORKTREE", document.new.path)
	set_buffer(state.left.buf, document.old.lines, document.old.path)
	set_buffer(state.right.buf, document.new.lines, document.new.path)
	arrange_content_windows(session)
	if state.left.win then
		M.configure_content_window(session, state.left.win)
	end
	if state.right.win then
		M.configure_content_window(session, state.right.win)
	end
	M.render_document(session)
	focus_first_hunk(session)
end

---@param session AtlasDiffSession
---@return AtlasDiffCurrent
function M.current(session)
	local state = session.viewer_state
	return {
		layout = state.layout,
		document = state.document,
		left = state.left,
		right = state.right,
	}
end

---@param session AtlasDiffSession
---@param output AtlasDiffRenderOutput
function M.render(session, output)
	local state = session.viewer_state
	state.annotated_paths = output.annotated_paths
	if state.layout == "inline" and state.right.win then
		renderer.inline_deleted_lines(state.document, state.right.buf, output.deleted_lines, output.deleted_hints)
	end
	explorer.render(session, output.annotated_paths)
	commits.render(session)
end

---@param session AtlasDiffSession
function M.open_commits(session)
	local state = session.viewer_state
	if
		not state.commits_visible
		or #session.commits == 0
		or not state.panel.win
		or not vim.api.nvim_win_is_valid(state.panel.win)
		or (state.commits_panel.win and vim.api.nvim_win_is_valid(state.commits_panel.win))
	then
		return
	end
	local height = math.max(1, math.floor(vim.api.nvim_win_get_height(state.panel.win) * 0.2))
	state.commits_panel.win = split_window(state.panel.win, state.commits_panel.buf, "below", height)
	explorer.configure_window(state.commits_panel.win)
	vim.wo[state.commits_panel.win].winfixheight = true
	statusline.attach(state.commits_panel.win)
	commits.render(session)
end

---@param session AtlasDiffSession
function M.close_commits(session)
	local state = session.viewer_state
	local win = state.commits_panel.win
	state.commits_panel.win = nil
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	end
end

---@param session AtlasDiffSession
function M.toggle_commits(session)
	local state = session.viewer_state
	if #session.commits == 0 then
		session_api.notify(session, "info", "No commits available")
		return
	end
	if not state.panel.win or not vim.api.nvim_win_is_valid(state.panel.win) then
		state.commits_visible = true
		M.toggle_explorer(session)
	else
		state.commits_visible = not state.commits_visible
		if state.commits_visible then
			M.open_commits(session)
		else
			M.close_commits(session)
		end
	end
	if state.commits_panel.win and vim.api.nvim_win_is_valid(state.commits_panel.win) then
		vim.api.nvim_set_current_win(state.commits_panel.win)
	end
end

---@param session AtlasDiffSession
function M.toggle_explorer(session)
	local state = session.viewer_state
	if state.panel.win and vim.api.nvim_win_is_valid(state.panel.win) then
		M.close_commits(session)
		local win = state.panel.win
		state.panel.win = nil
		vim.api.nvim_win_close(win, true)
		return
	end
	local anchor = state.left.win or state.right.win
	if not anchor or not vim.api.nvim_win_is_valid(anchor) then
		return
	end
	state.panel.win = split_window(anchor, state.panel.buf, "left", explorer.width(session))
	explorer.configure_window(state.panel.win)
	statusline.attach(state.panel.win)
	explorer.render(session, state.annotated_paths)
	M.open_commits(session)
end

---@param session AtlasDiffSession
---@param focus boolean|nil
function M.toggle_review_panel(session, focus)
	local panel = session.review_panel
	if not panel then
		return
	end
	if panel.win and vim.api.nvim_win_is_valid(panel.win) then
		review_panel.close(panel)
		return
	end
	local anchor = content_window(session.viewer_state)
	if anchor and vim.api.nvim_win_is_valid(anchor) then
		local win = review_panel.open(panel, anchor, focus ~= false)
		if win then
			statusline.attach(win)
		end
	end
end

---@param session AtlasDiffSession
---@return AtlasDiffCurrent|nil, string|nil
function M.toggle_layout(session)
	local state = session.viewer_state
	if state.document.status == "added" or state.document.status == "deleted" then
		return M.current(session), nil
	end
	local anchor = content_window(state)
	if not anchor or not vim.api.nvim_win_is_valid(anchor) then
		return nil, "The diff layout changed unexpectedly"
	end
	local current_win = vim.api.nvim_get_current_win()
	state.preferred_layout = state.layout == "side-by-side" and "inline" or "side-by-side"
	arrange_content_windows(session)
	if state.right.win then
		M.configure_content_window(session, state.right.win)
	end
	if state.left.win then
		M.configure_content_window(session, state.left.win)
	end
	M.render_document(session)
	if vim.api.nvim_win_is_valid(current_win) then
		vim.api.nvim_set_current_win(current_win)
	end
	return M.current(session), nil
end

---@param session AtlasDiffSession
---@return string|nil
function M.toggle_compact(session)
	local state = session.viewer_state
	if not state.compact and (state.document.binary or #state.document.changes == 0) then
		return "This file has no textual diff hunks"
	end
	state.compact = not state.compact
	if state.right.win then
		M.configure_content_window(session, state.right.win)
	end
	if state.left.win then
		M.configure_content_window(session, state.left.win)
	end
	M.render_document(session)
	return nil
end

---@param session AtlasDiffSession
---@param data AtlasNativeDiffData
---@param target AtlasLoadingTarget|nil
---@param options AtlasNativeDiffOptions
---@return string|nil
function M.create(session, data, target, options)
	local restore_options = target ~= nil
	if not target then
		vim.cmd("tabnew")
		local win = vim.api.nvim_get_current_win()
		target = {
			tabpage = vim.api.nvim_get_current_tabpage(),
			win = win,
			buf = vim.api.nvim_get_current_buf(),
			number = vim.wo[win].number,
			relativenumber = vim.wo[win].relativenumber,
		}
	end
	local tabpage = target.tabpage
	local right_win = target.win
	local launcher_buf = target.buf
	local number = target.number
	local relativenumber = target.relativenumber
	vim.api.nvim_set_current_tabpage(tabpage)
	vim.api.nvim_set_current_win(right_win)
	local right_buf = create_buffer(nil, "nowrite")
	local left_buf = create_buffer(nil, "nowrite")
	local panel_buf = create_buffer(string.format("atlas-diff://%d/files", tabpage))
	local commits_buf = create_buffer(string.format("atlas-diff://%d/commits", tabpage))
	vim.bo[panel_buf].filetype = "atlas.diff-files"
	vim.bo[panel_buf].syntax = "OFF"
	pcall(vim.treesitter.stop, panel_buf)
	vim.bo[commits_buf].filetype = "atlas.diff-commits"
	vim.bo[commits_buf].syntax = "OFF"
	pcall(vim.treesitter.stop, commits_buf)
	vim.api.nvim_win_set_buf(right_win, right_buf)
	if launcher_buf and vim.api.nvim_buf_is_valid(launcher_buf) then
		vim.api.nvim_buf_delete(launcher_buf, { force = true })
	end

	local panel_win = not options.explorer.hidden
			and split_window(
				right_win,
				panel_buf,
				"left",
				math.min(options.explorer.width, math.max(20, vim.o.columns - 40))
			)
		or nil
	if restore_options then
		for name, value in pairs({
			statuscolumn = target.statuscolumn,
			statusline = target.statusline,
			winbar = target.winbar,
		}) do
			vim.api.nvim_set_option_value(name, value, { win = right_win, scope = "local" })
		end
	end

	local additions, deletions = 0, 0
	for _, file in ipairs(data.files) do
		local added, deleted = diff.file_stats(file)
		additions = additions + added
		deletions = deletions + deleted
	end
	---@type AtlasNativeDiffState
	session.viewer_state = {
		tabpage = tabpage,
		range = data.range,
		files = data.files,
		document = data.document,
		selected_index = 1,
		pending_index = nil,
		layout = options.layout,
		preferred_layout = options.layout,
		compact = options.compact,
		compact_context_lines = options.compact_context_lines,
		number = number,
		relativenumber = relativenumber,
		explorer = options.explorer,
		collapsed_folders = {},
		panel_items = {},
		panel = { buf = panel_buf, win = panel_win },
		commits_panel = { buf = commits_buf, win = nil },
		commits_visible = options.explorer.show_commits and #session.commits > 0,
		commit_items = {},
		left = { buf = left_buf, win = nil },
		right = { buf = right_buf, win = right_win },
		annotated_paths = {},
		inline_deleted_lines = true,
		additions = additions,
		deletions = deletions,
		job = nil,
		group = nil,
		closing = false,
		lifecycle = target and target.diff_lifecycle or { session_id = session.id, opened = false, closed = false },
	}
	explorer.configure(session)
	if panel_win then
		statusline.attach(panel_win)
	end
	M.set_document(session, data.document)
	M.open_commits(session)
	local focus = options.explorer.initial_focus == "explorer" and panel_win or right_win
	vim.api.nvim_set_current_win(focus)
	return nil
end

---@param session AtlasDiffSession
function M.delete_buffers(session)
	local state = session.viewer_state
	for _, buf in ipairs({ state.panel.buf, state.commits_panel.buf, state.left.buf, state.right.buf }) do
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
end

---@param session AtlasDiffSession
---@return AtlasLoadingTarget|nil
function M.replace_with_loading(session)
	local state = session.viewer_state
	local tabpage, win = session.tabpage, content_window(state)
	if not tabpage or not vim.api.nvim_tabpage_is_valid(tabpage) or not win or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local target = {
		tabpage = tabpage,
		buf = vim.api.nvim_create_buf(false, true),
		win = win,
		number = state.number,
		relativenumber = state.relativenumber,
		statuscolumn = vim.wo[win].statuscolumn,
		statusline = vim.wo[win].statusline,
		winbar = vim.wo[win].winbar,
		diff_lifecycle = state.lifecycle,
	}
	vim.api.nvim_set_current_tabpage(tabpage)
	vim.api.nvim_set_current_win(win)
	vim.api.nvim_win_set_buf(win, target.buf)
	for _, other in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
		if other ~= win then
			pcall(vim.api.nvim_win_close, other, true)
		end
	end
	M.delete_buffers(session)
	return target
end

return M
