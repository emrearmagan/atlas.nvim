local events = require("atlas.core.events")
local logger = require("atlas.core.logger")
local notify = require("atlas.core.notify")
local actions = require("atlas.pulls.diff.actions")
local atlas = require("atlas.pulls.diff.atlas")
local keymaps = require("atlas.pulls.diff.keymaps")
local annotations = require("atlas.pulls.diff.ui.annotations")
local commits = require("atlas.pulls.diff.ui.commits")
local diff_statusline = require("atlas.pulls.diff.ui.statusline")
local explorer = require("atlas.pulls.diff.ui.explorer")
local review_panel = require("atlas.pulls.diff.ui.review_panel")
local winbar = require("atlas.pulls.diff.ui.winbar")
local picker = require("atlas.ui.picker")
local statusline = require("atlas.ui.statusline")

-- Those are the only supported renderer for now. Other commands will simply just open the diff with no built-in stuff.
local renderers = {
	AtlasDiff = "atlas.pulls.diff.atlas",
	CodeDiff = "atlas.pulls.diff.codediff",
	DiffviewOpen = "atlas.pulls.diff.diffview",
}

---@class AtlasDiffSelection
---@field file AtlasDiffFile
---@field side "LEFT"|"RIGHT"
---@field first integer
---@field last integer
---@field source_lines string[] All file lines on the selected side.
---@field inline PullsInlineCommentPosition

---@class AtlasDiffRenderer
---@field tabpage integer
---@field session AtlasDiffSession
---@field options AtlasPullsDiffConfig
---@field on_file fun(file: AtlasDiffFile|nil)
---@field current_file AtlasDiffFile|nil
---@field left { buf: integer, win?: integer }
---@field right { buf: integer, win: integer }
---@field annotations table<integer, table<integer, AtlasDiffAnnotation[]>> Stores comment/note annotations by buffer and line.
---@field expanded_threads table<string, boolean>
---@field show_file fun(self: AtlasDiffRenderer, file: AtlasDiffFile, on_done: fun(err?: string))
---@field redraw fun(self: AtlasDiffRenderer)
---@field get_selection fun(self: AtlasDiffRenderer): AtlasDiffSelection|nil, string|nil
---@field navigate_annotation fun(self: AtlasDiffRenderer, direction: 1|-1, kind: AtlasDiffAnnotationKind, from_edge?: boolean): boolean
---@field resize fun(self: AtlasDiffRenderer)
---@field setup_keymaps fun(self: AtlasDiffRenderer, viewer: AtlasDiffViewer, groups: AtlasDiffKeymapGroup[])
---@field dispose fun(self: AtlasDiffRenderer)

---@class AtlasDiffViewer
---@field id string|nil
---@field session AtlasDiffSession
---@field options AtlasPullsDiffConfig
---@field renderer AtlasDiffRenderer
---@field explorer AtlasDiffExplorer
---@field commits AtlasDiffCommits
---@field review_panel AtlasDiffReviewPanel
---@field statusline AtlasStatusline
---@field group integer|nil
local Viewer = {}
Viewer.__index = Viewer

---@param viewer AtlasDiffViewer
---@param name string
---@param reason string|nil
local function emit_event(viewer, name, reason)
	local session = viewer.session
	local file = viewer.renderer.current_file
	events.emit(name, {
		session_id = viewer.id,
		viewer = renderers[viewer.options.open_cmd]:match("[^.]+$"),
		tabpage = viewer.renderer.tabpage,
		root = session.range.root,
		base_revision = session.range.base_revision,
		head_revision = session.range.head_revision,
		path = file and file.path,
		status = file and file.status,
		reason = reason,
	})
end

local function close_tab(tabpage)
	if #vim.api.nvim_list_tabpages() == 1 then
		vim.cmd.tabnew()
		if statusline.enabled("diff") then
			vim.wo.statusline = vim.go.statusline
		end
	end

	vim.cmd.tabclose({ range = { vim.api.nvim_tabpage_get_number(tabpage) } })
end

---@param session AtlasDiffSession
---@param command string
---@return boolean, string|nil
local function open_command(session, command)
	vim.cmd.tabnew()
	local tabpage = vim.api.nvim_get_current_tabpage()

	local opened, err = pcall(function()
		vim.bo.bufhidden = "wipe"
		vim.bo.buflisted = false
		if statusline.enabled("diff") then
			vim.wo.statusline = vim.go.statusline
		end
		vim.wo.statuscolumn = vim.go.statuscolumn
		vim.wo.winbar = vim.go.winbar

		vim.cmd.tcd(vim.fn.fnameescape(session.range.root))
		vim.api.nvim_cmd({
			cmd = command,
			args = { session.range.base_revision .. "..." .. session.range.head_revision },
		}, {})
	end)

	if not opened or vim.api.nvim_get_current_tabpage() ~= tabpage then
		if vim.api.nvim_tabpage_is_valid(tabpage) then
			close_tab(tabpage)
		end
	end

	if not opened then
		return false, err
	end

	session:close()
	return true
end

---@param reason string|nil
function Viewer:close(reason)
	if self.session.closed then
		return
	end

	if self.group then
		vim.api.nvim_del_augroup_by_id(self.group)
	end

	annotations.close(self.renderer.tabpage)
	self.statusline:dispose()
	if vim.api.nvim_tabpage_is_valid(self.renderer.tabpage) then
		close_tab(self.renderer.tabpage)
	end
	self.renderer:dispose()

	if self.commits then
		self.commits:dispose()
	end
	if self.review_panel then
		self.review_panel:dispose()
	end
	if self.explorer then
		self.explorer:dispose()
	end

	self.session:close()

	if not self.id then
		return
	end

	emit_event(self, "AtlasDiffClosed", reason or "viewer_closed")
end

---@param viewer AtlasDiffViewer
---@param file AtlasDiffFile
---@param focus boolean|nil
---@param on_done (fun())|nil
local function select_file(viewer, file, focus, on_done)
	local session = viewer.session
	if session.closed then
		return
	end

	viewer.explorer:reveal(file)
	viewer.renderer:show_file(file, function(err)
		if err then
			logger.logerror("diff.show_file failed", {
				command = viewer.options.open_cmd,
				root = session.range.root,
				base = session.range.base_revision,
				head = session.range.head_revision,
				path = file.path,
				error = err,
			})
			notify.error("Unable to open " .. file.path .. "\n\n" .. err, { vim_notify = true })
			viewer.explorer:reveal(viewer.renderer.current_file)
			return
		end

		if focus and vim.api.nvim_get_current_win() == viewer.explorer.win then
			vim.api.nvim_set_current_win(viewer.renderer.right.win)
		end
		if on_done then
			on_done()
		end
	end)
end

---@param viewer AtlasDiffViewer
local function update_statusline(viewer)
	diff_statusline.update(viewer.statusline, viewer.session, viewer.explorer.files, viewer.renderer.right.buf)
end

---@param viewer AtlasDiffViewer
local function update_panels(viewer)
	local session = viewer.session
	local reviewed_files = not session:shows_commit() and session.reviewed_files or nil
	viewer.explorer:update(reviewed_files, session.review, session.notes and session.notes.items)
	viewer.review_panel:render()
	update_statusline(viewer)
end

---@param viewer AtlasDiffViewer
local function update_review(viewer)
	viewer.renderer:redraw()
	update_panels(viewer)
end

function Viewer:show_details()
	local file = self.renderer.current_file
	local items = annotations.at_cursor(self.renderer)
	if not file or not items then
		vim.lsp.buf.hover()
		return
	end

	annotations.open(
		self.renderer.tabpage,
		self.session.source.pr,
		file.path,
		items,
		function(action, target, on_submit)
			---@type AtlasDiffActionContext
			local context = {
				session = self.session,
				comment = target.comment,
				note = target.note,
				pending = target.pending,
				on_submit = on_submit,
			}
			self:run_action(action, context)
		end
	)
end

---@param action "delete_comment"|"toggle_resolved"
function Viewer:run_annotation_action(action)
	local items = annotations.at_cursor(self.renderer)
	if not items or #items == 0 then
		return
	end
	if #items > 1 then
		self:show_details()
		return
	end

	local item = items[1]
	---@type AtlasDiffActionContext
	local context = { session = self.session }
	---@type AtlasReviewActionId
	local selected_action = action
	if item.note then
		context.note = item.note
		selected_action = action == "delete_comment" and "delete_note" or "toggle_note_resolved"
	else
		context.comment = item.thread.comment
		if action == "toggle_resolved" and item.thread.comment.is_task then
			selected_action = "toggle_task"
		end
	end

	self:run_action(selected_action, context)
end

---@param direction 1|-1
---@param unreviewed_only boolean|nil
function Viewer:navigate_file(direction, unreviewed_only)
	local files = self.explorer.files
	if #files == 0 then
		return
	end

	local position = self.explorer:current_index() or 1
	local steps = unreviewed_only and #files - 1 or 1
	local reviewed_files = self.explorer.reviewed_files or {}

	for offset = 1, steps do
		local file = files[((position - 1 + direction * offset) % #files) + 1]
		if not unreviewed_only or not reviewed_files[file.path] then
			select_file(self, file)
			return
		end
	end

	notify.info("No other unreviewed files")
end

---@param direction 1|-1
---@param kind AtlasDiffAnnotationKind
function Viewer:navigate_annotation(direction, kind)
	if self.renderer:navigate_annotation(direction, kind) then
		return
	end

	local files = self.explorer.files
	local index = direction == 1 and 0 or 1
	for position, file in ipairs(files) do
		if file == self.renderer.current_file then
			index = position
			break
		end
	end

	for offset = 1, #files do
		local file = files[((index - 1 + direction * offset) % #files) + 1]
		local items = annotations.for_file(self.session, file)
		if vim.iter(items):any(function(item)
			return annotations.is_kind(item, kind)
		end) then
			select_file(self, file, nil, function()
				self.renderer:navigate_annotation(direction, kind, true)
			end)
			return
		end
	end
end

---@param viewer AtlasDiffViewer
---@return AtlasDiffFile|nil
local function current_file(viewer)
	if vim.api.nvim_get_current_buf() == viewer.explorer.buf then
		return viewer.explorer:current_file()
	end
	return viewer.renderer.current_file
end

function Viewer:toggle_file_reviewed()
	local session = self.session
	local reviewed_files = session.reviewed_files
	if not reviewed_files then
		return
	end
	-- NOTE: Reviewed marks belong to the whole PR, so a single commit can't set them for now. We could allow it when no
	-- later commit changes the file and every earlier commit that did was already seen, since then you've looked at
	-- its whole PR diff. Also we would probably need a least to track all reviewed files for each individual commit ?
	-- So coming back to a commit still shows them as reviewed ?
	if session:shows_commit() then
		notify.info("Can't mark files reviewed at the commit level")
		return
	end

	if vim.api.nvim_get_current_buf() == self.explorer.buf then
		local files = self.explorer:files_under_cursor()
		if #files > 0 then
			session:set_reviewed(files, not reviewed_files[files[1].path])
			update_panels(self)
			return
		end
	end

	local file = current_file(self)
	if not file then
		return
	end

	local files = self.explorer.files
	local next_file
	for index, item in ipairs(files) do
		if item == file then
			next_file = files[index % #files + 1]
			break
		end
	end

	session:set_reviewed({ file }, not reviewed_files[file.path])
	update_panels(self)

	if next_file and next_file ~= file then
		select_file(self, next_file)
	else
		self.explorer:reveal(file)
	end
end

function Viewer:find_file()
	picker.select({
		title = "Changed files",
		items = self.explorer.files,
		initial_index = self.explorer:current_index(),
		format_item = function(file)
			return file.path
		end,
		on_select = function(file)
			if file then
				select_file(self, file)
			end
		end,
	})
end

---@param viewer AtlasDiffViewer
local function resize(viewer)
	-- Closing the whole tab also queues the review panel's resize callback.
	if not vim.api.nvim_win_is_valid(viewer.renderer.right.win) then
		return
	end

	viewer.explorer:resize()
	viewer.commits:resize(viewer.explorer.win)
	viewer.renderer:resize()
end

function Viewer:focus_explorer()
	if not self.explorer.win then
		local win = self.explorer:toggle()
		self.statusline:attach(win)
		resize(self)
	end

	vim.api.nvim_set_current_win(self.explorer.win)
end

function Viewer:toggle_explorer()
	if self.explorer.win then
		self.commits:close()
	end

	local win = self.explorer:toggle()
	if win then
		self.statusline:attach(win)
		if self.commits.shown then
			local commits_win = self.commits:open(win)
			self.statusline:attach(commits_win)
		end
	end
	resize(self)
end

function Viewer:toggle_commits()
	if self.commits.win then
		self.commits.shown = false
		self.commits:close()
		return
	end

	if not self.explorer.win and #self.commits.items > 0 then
		local win = self.explorer:toggle()
		self.statusline:attach(win)
		resize(self)
	end

	local win, err = self.commits:open(self.explorer.win)
	if not win then
		---@cast err string
		notify.info(err)
		return
	end

	self.commits.shown = true
	self.statusline:attach(win)
	vim.api.nvim_set_current_win(win)
end

function Viewer:toggle_review_panel()
	local panel = self.review_panel
	if panel.win then
		panel:close()
		return
	end

	local win = panel:open()
	self.statusline:attach(win)
	vim.api.nvim_set_current_win(win)
end

---@param viewer AtlasDiffViewer
---@param entry AtlasDiffReviewPanelRow
---@param focus boolean
local function open_review_item(viewer, entry, focus)
	local comment = entry.thread_root or entry.comment
	local position = comment and (comment.file or comment.inline)
	local path = entry.note and entry.note.file_path or position and position.path
	if not path then
		return
	end

	local file = vim.iter(viewer.session.files):find(function(item)
		return item.path == path or item.old_path == path
	end)
	if not file then
		notify.info("File is not in this diff")
		return
	end

	select_file(viewer, file, false, function()
		if focus then
			vim.api.nvim_set_current_win(viewer.renderer.right.win)
		end
		annotations.jump(viewer.renderer, { comment = comment, note = entry.note }, focus)
	end)
end

---@param viewer AtlasDiffViewer
local function setup_autocmds(viewer)
	local renderer = viewer.renderer
	viewer.group = vim.api.nvim_create_augroup("AtlasDiff" .. renderer.tabpage, { clear = true })

	vim.api.nvim_create_autocmd({ "LspAttach", "LspDetach" }, {
		group = viewer.group,
		-- Let Neovim finish updating the buffer's attached clients.
		callback = vim.schedule_wrap(function(event)
			if not viewer.session.closed and event.buf == renderer.right.buf then
				update_statusline(viewer)
			end
		end),
	})

	vim.api.nvim_create_autocmd("VimResized", {
		group = viewer.group,
		callback = function()
			viewer.review_panel:resize()
			resize(viewer)
		end,
	})

	vim.api.nvim_create_autocmd("TabClosed", {
		group = viewer.group,
		callback = function()
			if not vim.api.nvim_tabpage_is_valid(renderer.tabpage) then
				viewer:close("tab_closed")
			end
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = viewer.group,
		callback = vim.schedule_wrap(function(event)
			local win = tonumber(event.match)
			if win == renderer.right.win or win == renderer.left.win then
				viewer:close("window_closed")
				return
			end
			if not viewer.explorer.win and viewer.commits.win then
				viewer.commits:close()
			end
		end),
	})
end

function Viewer:reload()
	require("atlas.pulls.diff").reopen(self.session)
	self:close("refresh")
end

---@param id AtlasReviewActionId
---@param context AtlasDiffActionContext|nil
function Viewer:run_action(id, context)
	actions.dispatch(id, context or { session = self.session }, function()
		update_review(self)
	end)
end

---@param callback fun(context: AtlasPullActionContext, done: fun(result: PullsActionResult|nil, err: string|nil)): any
---@return any
function Viewer:run_custom(callback)
	return actions.run_custom(callback, { session = self.session }, function()
		update_review(self)
	end)
end

function Viewer:toggle_comments()
	local options = self.options
	options.comment_display = options.comment_display == "virtual_lines" and "virtual_text" or "virtual_lines"
	self.renderer:redraw()
end

---@param all boolean|nil
---@return boolean toggled
function Viewer:toggle_threads(all)
	if not annotations.toggle_threads(self.renderer, all) then
		return false
	end

	self.renderer:redraw()
	return true
end

---@param pending boolean
---@param suggestion boolean|nil
function Viewer:add_comment(pending, suggestion)
	if self.session:shows_commit() then
		notify.info("Can't comment at the commit level")
		return
	end

	if vim.api.nvim_get_current_buf() == self.explorer.buf then
		local file = self.explorer:current_file()
		if file then
			self:run_action("add_comment", { session = self.session, file = file, pending = pending })
		end
		return
	end

	local selection, err = self.renderer:get_selection()
	if not selection then
		if err then
			notify.info(err)
		end
		return
	end

	self:run_action("add_comment", {
		session = self.session,
		selection = selection,
		pending = pending,
		suggestion = suggestion,
	})
end

function Viewer:add_note()
	if self.session:shows_commit() then
		notify.info("Can't add notes at the commit level")
		return
	end

	local selection, err = self.renderer:get_selection()
	if not selection then
		if err then
			notify.info(err)
		end
		return
	end

	self:run_action("add_note", { session = self.session, selection = selection })
end

function Viewer:open_in_browser()
	local annotation = vim.iter(annotations.at_cursor(self.renderer) or {}):find(function(item)
		local url = item.thread and item.thread.comment.url
		return url ~= nil and url ~= ""
	end)
	self:run_action("open_in_browser", { session = self.session, comment = annotation and annotation.thread.comment })
end

function Viewer:open_file()
	local file = current_file(self)
	if not file then
		return
	end

	local path = vim.fs.joinpath(self.session.range.root, file.path)
	if vim.fn.filereadable(path) ~= 1 then
		notify.warn("File not found")
		return
	end

	vim.cmd.tabedit({ args = { path } })
	local options = vim.wo[0][0]
	if statusline.enabled("diff") then
		options.statusline = vim.go.statusline
	end
	options.winbar = vim.go.winbar
	options.winhighlight = vim.go.winhighlight
end

---@param commit AtlasGitCommit|nil
function Viewer:show_commit(commit)
	local session = self.session
	local shown = session:shows_commit() and session.range.head_revision or nil
	if (commit and commit.hash) == shown then
		return
	end

	-- Diffview fixes its revisions when the view is built, so supporting this here would mean
	-- recreating the whole Diffview view. Can't be bothered yet tho..
	if self.options.open_cmd == "DiffviewOpen" then
		notify.info("Showing a single commit needs AtlasDiff or CodeDiff")
		return
	end

	session:show_commit(commit, function()
		self.commits:set_active(commit and commit.hash)
		self.explorer:set_files(session.files)
		update_panels(self)
		local first = self.explorer.files[1]
		if first then
			select_file(self, first)
		end
	end)
end

---@param direction 1|-1
function Viewer:step_commit(direction)
	local session = self.session
	if #session.commits == 0 then
		notify.info("No commits available")
		return
	end

	local index = direction == 1 and #session.commits or 1
	if session:shows_commit() then
		for position, commit in ipairs(session.commits) do
			if commit.hash == session.range.head_revision then
				index = position - direction
			end
		end
	end

	local commit = session.commits[index]
	if not commit then
		notify.info(direction == 1 and "Last commit" or "First commit")
		return
	end
	self:show_commit(commit)
end

---@param session AtlasDiffSession
---@param options AtlasPullsDiffConfig
---@param err any
local function fallback(session, options, err)
	local command = options.open_cmd
	local pr = session.source.pr
	logger.logwarn("diff.open fallback", {
		command = command,
		provider = pr and pr.provider,
		repo = pr and pr.repo_full_name,
		pr_id = pr and pr.id,
		root = session.range.root,
		base = session.range.base_revision,
		head = session.range.head_revision,
		error = tostring(err),
	})
	notify.warn(command .. " failed to open. Opening Atlas instead.", { vim_notify = true })
	options.open_cmd = "AtlasDiff"
end

---@param viewer AtlasDiffViewer
---@param file AtlasDiffFile|nil
local function on_file(viewer, file)
	local changed = viewer.renderer.current_file ~= file
	viewer.renderer.current_file = file
	winbar.update(viewer.renderer)
	update_statusline(viewer)
	if viewer.explorer.selected ~= file then
		viewer.explorer:reveal(file)
	end

	keymaps.setup(viewer)
	for _, pane in pairs({ viewer.renderer.left, viewer.renderer.right }) do
		viewer.statusline:attach(pane.win)
	end

	if changed and viewer.id then
		emit_event(viewer, "AtlasDiffFileChanged")
	end
end

---@param viewer AtlasDiffViewer
---@param module string
local function open_renderer(viewer, module)
	local session = viewer.session
	local options = viewer.options
	local function file_changed(file)
		on_file(viewer, file)
	end

	local opened, renderer = pcall(function()
		return require(module).new(session, options, file_changed)
	end)
	if not opened then
		if options.open_cmd == "AtlasDiff" then
			error(renderer, 0)
		end

		fallback(session, options, renderer)
		renderer = atlas.new(session, options, file_changed)
	end

	viewer.renderer = renderer
end

---@param viewer AtlasDiffViewer
local function setup(viewer)
	local session = viewer.session
	local options = viewer.options
	local renderer = viewer.renderer
	local explorer_options = options.explorer
	---@cast explorer_options AtlasPullsDiffExplorerConfig

	vim.cmd.tcd(vim.fn.fnameescape(session.range.root))

	viewer.commits = commits.new(session.commits, explorer_options.show_commits)
	viewer.review_panel = review_panel.new(session, options.review_panel, {
		on_resize = function()
			resize(viewer)
		end,
		on_select = function(entry, focus)
			open_review_item(viewer, entry, focus)
		end,
		on_action = function(id, target)
			viewer:run_action(id, {
				session = session,
				comment = target.comment,
				note = target.note,
				review_entry = target.review_entry,
				pending = target.pending,
			})
		end,
	})
	viewer.explorer = explorer.new({
		files = session.files,
		options = explorer_options,
		reviewed_files = session.reviewed_files,
		review_data = session.review,
		notes = session.notes and session.notes.items,
		on_select = function(file, focus)
			select_file(viewer, file, focus)
		end,
	})

	if session.source.kind == "pr" and not options.review_panel.hidden then
		viewer.review_panel:open()
	end
	if viewer.commits.shown and viewer.explorer.win then
		viewer.commits:open(viewer.explorer.win)
	end
	resize(viewer)

	setup_autocmds(viewer)
	keymaps.setup(viewer)

	update_statusline(viewer)
	for _, pane in pairs({ renderer.left, renderer.right, viewer.explorer, viewer.commits, viewer.review_panel }) do
		viewer.statusline:attach(pane.win)
	end

	local focus_win = explorer_options.initial_focus == "explorer" and viewer.explorer.win or renderer.right.win
	vim.api.nvim_set_current_win(focus_win)

	local first = viewer.explorer.files[1]
	if first then
		select_file(viewer, first)
	end
end

---@param session AtlasDiffSession
---@param options AtlasPullsDiffConfig
function Viewer.open(session, options)
	local module = renderers[options.open_cmd]
	if not module then
		local opened, err = open_command(session, options.open_cmd)
		if opened then
			return
		end

		fallback(session, options, err)
		module = renderers.AtlasDiff
	end

	local viewer = setmetatable({
		session = session,
		options = options,
		statusline = statusline.new({ context = "diff" }),
	}, Viewer)

	open_renderer(viewer, module)

	local opened, err = pcall(setup, viewer)
	if not opened then
		viewer:close()
		error(err, 0)
	end

	viewer.id = events.new_id(renderers[options.open_cmd]:match("[^.]+$"))
	emit_event(viewer, "AtlasDiffOpened")
	-- The first file may already be loaded during setup.
	if viewer.renderer.current_file then
		emit_event(viewer, "AtlasDiffFileChanged")
	end
end

return Viewer
