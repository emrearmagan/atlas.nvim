local events = require("atlas.core.events")
local logger = require("atlas.core.logger")
local notify = require("atlas.core.notify")
local actions = require("atlas.pulls.diff.actions")
local atlas = require("atlas.pulls.diff.atlas")
local keymaps = require("atlas.pulls.diff.keymaps")
local diff_session = require("atlas.pulls.diff.session")
local annotations = require("atlas.pulls.diff.ui.annotations")
local commits = require("atlas.pulls.diff.ui.commits")
local diff_statusline = require("atlas.pulls.diff.ui.statusline")
local explorer = require("atlas.pulls.diff.ui.explorer")
local review_panel = require("atlas.pulls.diff.ui.review_panel")
local winbar = require("atlas.pulls.diff.ui.winbar")
local picker = require("atlas.ui.picker")
local statusline = require("atlas.ui.statusline")

local M = {}

-- Those are the only supported renderer for now. Other commands will simply just open the diff with no built-in stuff.
local renderers = {
	AtlasDiff = "atlas.pulls.diff.atlas",
	CodeDiff = "atlas.pulls.diff.codediff",
	DiffviewOpen = "atlas.pulls.diff.diffview",
}

---@class AtlasDiffView
---@field tabpage integer
---@field session AtlasDiffSession
---@field options AtlasPullsDiffConfig
---@field callbacks AtlasDiffCallbacks
---@field current_file AtlasDiffFile|nil
---@field left { buf: integer, win?: integer }
---@field right { buf: integer, win: integer }
---@field annotations table<integer, table<integer, AtlasDiffAnnotation[]>> Stores comment/note annotations by buffer and line.
---@field expanded_threads table<string, boolean>

---@class AtlasDiffSelection
---@field file AtlasDiffFile
---@field side "LEFT"|"RIGHT"
---@field first integer
---@field last integer
---@field source_lines string[] All file lines on the selected side.
---@field inline PullsInlineCommentPosition

---@class AtlasDiffCallbacks
---@field on_file fun(file: AtlasDiffFile|nil)
---@field show_details fun()

---@class AtlasDiffRenderer
---@field open fun(session: AtlasDiffSession, options: AtlasPullsDiffConfig, callbacks: AtlasDiffCallbacks): AtlasDiffView
---@field show_file fun(view: AtlasDiffView, file: AtlasDiffFile, on_done: fun(err?: string))
---@field redraw fun(view: AtlasDiffView)
---@field get_selection fun(view: AtlasDiffView): AtlasDiffSelection|nil, string|nil
---@field navigate_annotation fun(view: AtlasDiffView, direction: 1|-1, kind: AtlasDiffAnnotationKind, from_edge?: boolean): boolean
---@field resize fun(view: AtlasDiffView)
---@field setup_keymaps fun(ui: AtlasDiffUI, actions: AtlasDiffKeymapActions, groups: AtlasDiffKeymapGroup[])
---@field dispose fun(view: AtlasDiffView)

---@class AtlasDiffUI
---@field id string|nil
---@field session AtlasDiffSession
---@field options AtlasPullsDiffConfig
---@field renderer AtlasDiffRenderer
---@field view AtlasDiffView
---@field explorer AtlasDiffExplorer
---@field commits { buf: integer, win?: integer, shown: boolean, items: PullsCommit[], cursor_row: integer, group: integer }
---@field review_panel AtlasDiffReviewPanel
---@field statusline AtlasStatusline
---@field group integer|nil

---@param ui AtlasDiffUI
---@param name string
---@param reason string|nil
local function emit_event(ui, name, reason)
	local session = ui.session
	local file = ui.view.current_file
	events.emit(name, {
		session_id = ui.id,
		viewer = renderers[ui.options.open_cmd]:match("[^.]+$"),
		tabpage = ui.view.tabpage,
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

	diff_session.close(session)
	return true
end

---@param ui AtlasDiffUI
---@param reason string|nil
local function close(ui, reason)
	if ui.session.closed then
		return
	end

	if ui.group then
		vim.api.nvim_del_augroup_by_id(ui.group)
	end

	annotations.close(ui.view.tabpage)
	ui.statusline:dispose()
	if vim.api.nvim_tabpage_is_valid(ui.view.tabpage) then
		close_tab(ui.view.tabpage)
	end
	ui.renderer.dispose(ui.view)

	if ui.commits then
		commits.dispose(ui.commits)
	end
	if ui.review_panel then
		review_panel.dispose(ui.review_panel)
	end
	if ui.explorer then
		explorer.dispose(ui.explorer)
	end

	diff_session.close(ui.session)

	if not ui.id then
		return
	end

	emit_event(ui, "AtlasDiffClosed", reason or "viewer_closed")
end

---@param ui AtlasDiffUI
---@param file AtlasDiffFile
---@param focus boolean|nil
---@param on_done (fun())|nil
local function select_file(ui, file, focus, on_done)
	local session = ui.session
	if session.closed then
		return
	end

	explorer.reveal(ui.explorer, file)
	ui.renderer.show_file(ui.view, file, function(err)
		if err then
			logger.logerror("diff.show_file failed", {
				command = ui.options.open_cmd,
				root = session.range.root,
				base = session.range.base_revision,
				head = session.range.head_revision,
				path = file.path,
				error = err,
			})
			notify.error("Unable to open " .. file.path .. "\n\n" .. err, { vim_notify = true })
			explorer.reveal(ui.explorer, ui.view.current_file)
			return
		end

		if focus and vim.api.nvim_get_current_win() == ui.explorer.win then
			vim.api.nvim_set_current_win(ui.view.right.win)
		end
		if on_done then
			on_done()
		end
	end)
end

---@param ui AtlasDiffUI
local function update_panels(ui)
	local session = ui.session
	explorer.update(ui.explorer, session.reviewed_files, session.review, session.notes and session.notes.items)
	review_panel.render(ui.review_panel)
	diff_statusline.update(ui)
end

---@param ui AtlasDiffUI
local function update_review(ui)
	ui.renderer.redraw(ui.view)
	update_panels(ui)
end

---@param ui AtlasDiffUI
local function show_details(ui)
	local file = ui.view.current_file
	local items = annotations.at_cursor(ui.view)
	if not file or not items then
		vim.lsp.buf.hover()
		return
	end

	annotations.open(ui.view.tabpage, ui.session.source.pr, file.path, items, function(action, target, on_submit)
		---@type AtlasDiffActionContext
		local context = {
			session = ui.session,
			comment = target.comment,
			note = target.note,
			pending = target.pending,
			on_submit = on_submit,
		}
		actions.dispatch(action, context, function()
			update_review(ui)
		end)
	end)
end

---@param ui AtlasDiffUI
---@param action "delete_comment"|"toggle_resolved"
local function dispatch_annotation(ui, action)
	local items = annotations.at_cursor(ui.view)
	if not items or #items == 0 then
		return
	end
	if #items > 1 then
		show_details(ui)
		return
	end

	local item = items[1]
	---@type AtlasDiffActionContext
	local context = { session = ui.session }
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

	actions.dispatch(selected_action, context, function()
		update_review(ui)
	end)
end

---@param ui AtlasDiffUI
---@param direction 1|-1
---@param unreviewed_only boolean|nil
local function navigate_file(ui, direction, unreviewed_only)
	local files = ui.explorer.files
	if #files == 0 then
		return
	end

	local position = explorer.current_index(ui.explorer) or 1
	local steps = unreviewed_only and #files - 1 or 1
	local reviewed_files = ui.session.reviewed_files or {}

	for offset = 1, steps do
		local file = files[((position - 1 + direction * offset) % #files) + 1]
		if not unreviewed_only or not reviewed_files[file.path] then
			select_file(ui, file)
			return
		end
	end

	notify.info("No other unreviewed files")
end

---@param ui AtlasDiffUI
---@param direction 1|-1
---@param kind AtlasDiffAnnotationKind
local function navigate_annotation(ui, direction, kind)
	if ui.renderer.navigate_annotation(ui.view, direction, kind) then
		return
	end

	local files = ui.explorer.files
	local index = direction == 1 and 0 or 1
	for position, file in ipairs(files) do
		if file == ui.view.current_file then
			index = position
			break
		end
	end

	for offset = 1, #files do
		local file = files[((index - 1 + direction * offset) % #files) + 1]
		local items = annotations.for_file(ui.session, file)
		if vim.iter(items):any(function(item)
			return annotations.is_kind(item, kind)
		end) then
			select_file(ui, file, nil, function()
				ui.renderer.navigate_annotation(ui.view, direction, kind, true)
			end)
			return
		end
	end
end

---@param ui AtlasDiffUI
---@return AtlasDiffFile|nil
local function current_file(ui)
	if vim.api.nvim_get_current_buf() == ui.explorer.buf then
		return explorer.current_file(ui.explorer)
	end
	return ui.view.current_file
end

---@param ui AtlasDiffUI
local function toggle_file_reviewed(ui)
	local session = ui.session
	local reviewed_files = session.reviewed_files
	if not reviewed_files then
		return
	end

	if vim.api.nvim_get_current_buf() == ui.explorer.buf then
		local files = vim.tbl_filter(function(file)
			return not session.reviewed_requests[file.path]
		end, explorer.files_under_cursor(ui.explorer))
		if #files > 0 then
			diff_session.set_reviewed(session, files, not reviewed_files[files[1].path])
			update_panels(ui)
			return
		end
	end

	local file = current_file(ui)
	if not file or session.reviewed_requests[file.path] then
		return
	end

	local files = ui.explorer.files
	local next_file
	for index, item in ipairs(files) do
		if item == file then
			next_file = files[index % #files + 1]
			break
		end
	end

	diff_session.set_reviewed(session, { file }, not reviewed_files[file.path])
	update_panels(ui)

	if next_file and next_file ~= file then
		select_file(ui, next_file)
	else
		explorer.reveal(ui.explorer, file)
	end
end

---@param ui AtlasDiffUI
local function find_file(ui)
	picker.select({
		title = "Changed files",
		items = ui.explorer.files,
		initial_index = explorer.current_index(ui.explorer),
		format_item = function(file)
			return file.path
		end,
		on_select = function(file)
			if file then
				select_file(ui, file)
			end
		end,
	})
end

---@param ui AtlasDiffUI
local function resize(ui)
	-- Closing the whole tab also queues the review panel's resize callback.
	if not vim.api.nvim_win_is_valid(ui.view.right.win) then
		return
	end

	explorer.resize(ui.explorer)
	commits.resize(ui.commits, ui.explorer.win)
	ui.renderer.resize(ui.view)
end

---@param ui AtlasDiffUI
local function focus_explorer(ui)
	if not ui.explorer.win then
		local win = explorer.toggle(ui.explorer)
		ui.statusline:attach(win)
		resize(ui)
	end

	vim.api.nvim_set_current_win(ui.explorer.win)
end

---@param ui AtlasDiffUI
local function toggle_explorer(ui)
	if ui.explorer.win then
		commits.close(ui.commits)
	end

	local win = explorer.toggle(ui.explorer)
	if win then
		ui.statusline:attach(win)
		if ui.commits.shown then
			local commits_win = commits.open(ui.commits, win)
			ui.statusline:attach(commits_win)
		end
	end
	resize(ui)
end

---@param ui AtlasDiffUI
local function toggle_commits(ui)
	if ui.commits.win then
		ui.commits.shown = false
		commits.close(ui.commits)
		return
	end

	if not ui.explorer.win and #ui.commits.items > 0 then
		local win = explorer.toggle(ui.explorer)
		ui.statusline:attach(win)
		resize(ui)
	end

	local win, err = commits.open(ui.commits, ui.explorer.win)
	if not win then
		---@cast err string
		notify.info(err)
		return
	end

	ui.commits.shown = true
	ui.statusline:attach(win)
	vim.api.nvim_set_current_win(win)
end

---@param ui AtlasDiffUI
local function toggle_review_panel(ui)
	local panel = ui.review_panel
	if panel.win then
		review_panel.close(panel)
		return
	end

	local win = review_panel.open(panel)
	ui.statusline:attach(win)
	vim.api.nvim_set_current_win(win)
end

---@param ui AtlasDiffUI
---@param entry AtlasDiffReviewPanelRow
---@param focus boolean
local function open_review_item(ui, entry, focus)
	local comment = entry.thread_root or entry.comment
	local position = comment and (comment.file or comment.inline)
	local path = entry.note and entry.note.file_path or position and position.path
	if not path then
		return
	end

	local file = vim.iter(ui.session.files):find(function(item)
		return item.path == path or item.old_path == path
	end)
	if not file then
		notify.info("File is not in this diff")
		return
	end

	select_file(ui, file, false, function()
		if focus then
			vim.api.nvim_set_current_win(ui.view.right.win)
		end
		annotations.jump(ui.view, { comment = comment, note = entry.note }, focus)
	end)
end

---@param ui AtlasDiffUI
local function setup_autocmds(ui)
	local view = ui.view
	ui.group = vim.api.nvim_create_augroup("AtlasDiff" .. view.tabpage, { clear = true })

	vim.api.nvim_create_autocmd({ "LspAttach", "LspDetach" }, {
		group = ui.group,
		-- Let Neovim finish updating the buffer's attached clients.
		callback = vim.schedule_wrap(function(event)
			if not ui.session.closed and event.buf == view.right.buf then
				diff_statusline.update(ui)
			end
		end),
	})

	vim.api.nvim_create_autocmd("VimResized", {
		group = ui.group,
		callback = function()
			review_panel.resize(ui.review_panel)
			resize(ui)
		end,
	})

	vim.api.nvim_create_autocmd("TabClosed", {
		group = ui.group,
		callback = function()
			if not vim.api.nvim_tabpage_is_valid(view.tabpage) then
				close(ui, "tab_closed")
			end
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = ui.group,
		callback = vim.schedule_wrap(function(event)
			local win = tonumber(event.match)
			if win == view.right.win or win == view.left.win then
				close(ui, "window_closed")
				return
			end
			if not ui.explorer.win and ui.commits.win then
				commits.close(ui.commits)
			end
		end),
	})
end

---@param ui AtlasDiffUI
local function setup_keymaps(ui)
	local session = ui.session
	local view = ui.view
	local function on_review_updated()
		update_review(ui)
	end

	keymaps.setup(ui, {
		close = function()
			close(ui, "user_close")
		end,
		reload = function()
			require("atlas.pulls.diff").reopen(session)
			close(ui, "refresh")
		end,
		toggle_explorer = function()
			toggle_explorer(ui)
		end,
		toggle_commits = function()
			toggle_commits(ui)
		end,
		toggle_review_panel = function()
			toggle_review_panel(ui)
		end,
		toggle_file_reviewed = function()
			toggle_file_reviewed(ui)
		end,
		toggle_resolved = function()
			dispatch_annotation(ui, "toggle_resolved")
		end,
		delete_annotation = function()
			dispatch_annotation(ui, "delete_comment")
		end,
		toggle_comments = function()
			local options = ui.options
			options.comment_display = options.comment_display == "virtual_lines" and "virtual_text" or "virtual_lines"
			ui.renderer.redraw(view)
		end,
		toggle_threads = function(all)
			if not annotations.toggle_threads(view, all) then
				return false
			end

			ui.renderer.redraw(view)
			return true
		end,
		add_comment = function(pending, suggestion)
			if vim.api.nvim_get_current_buf() == ui.explorer.buf then
				local file = explorer.current_file(ui.explorer)
				if file then
					actions.dispatch("add_comment", {
						session = session,
						file = file,
						pending = pending,
					}, on_review_updated)
				end
				return
			end

			local selection, err = ui.renderer.get_selection(view)
			if not selection then
				if err then
					notify.info(err)
				end
				return
			end

			actions.dispatch("add_comment", {
				session = session,
				selection = selection,
				pending = pending,
				suggestion = suggestion,
			}, on_review_updated)
		end,
		add_note = function()
			local selection, err = ui.renderer.get_selection(view)
			if not selection then
				if err then
					notify.info(err)
				end
				return
			end

			actions.dispatch("add_note", { session = session, selection = selection }, on_review_updated)
		end,
		navigate_annotation = function(direction, kind)
			navigate_annotation(ui, direction, kind)
		end,
		dispatch = function(id)
			actions.dispatch(id, { session = session }, on_review_updated)
		end,
		run_custom = function(callback)
			return actions.run_custom(callback, { session = session }, on_review_updated)
		end,
		open_in_browser = function()
			local annotation = vim.iter(annotations.at_cursor(view) or {}):find(function(item)
				local url = item.thread and item.thread.comment.url
				return url ~= nil and url ~= ""
			end)
			actions.dispatch(
				"open_in_browser",
				{ session = session, comment = annotation and annotation.thread.comment }
			)
		end,
		navigate_file = function(direction, unreviewed_only)
			navigate_file(ui, direction, unreviewed_only)
		end,
		find_file = function()
			find_file(ui)
		end,
		open_file = function()
			local file = current_file(ui)
			if not file then
				return
			end

			local path = vim.fs.joinpath(session.range.root, file.path)
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
		end,
		open_commit = function()
			local commit = commits.current(ui.commits)
			if not commit then
				return
			end

			require("atlas.pulls.diff").open_commit({ commit = commit.hash, root = session.range.root })
		end,
		focus_explorer = function()
			focus_explorer(ui)
		end,
	})
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

---@param ui AtlasDiffUI
---@param module string
local function open_view(ui, module)
	local session = ui.session
	local options = ui.options
	local callbacks = {
		on_file = function(file)
			local changed = ui.view.current_file ~= file
			ui.view.current_file = file
			winbar.update(ui.view)
			diff_statusline.update(ui)
			if ui.explorer.selected ~= file then
				explorer.reveal(ui.explorer, file)
			end

			setup_keymaps(ui)
			for _, pane in pairs({ ui.view.left, ui.view.right }) do
				ui.statusline:attach(pane.win)
			end

			if changed and ui.id then
				emit_event(ui, "AtlasDiffFileChanged")
			end
		end,
		show_details = function()
			show_details(ui)
		end,
	}

	---@type AtlasDiffRenderer
	local renderer
	local view_opened, view = pcall(function()
		renderer = require(module)
		return renderer.open(session, options, callbacks)
	end)

	if not view_opened then
		if options.open_cmd == "AtlasDiff" then
			error(view, 0)
		end

		fallback(session, options, view)
		renderer = atlas
		view = renderer.open(session, options, callbacks)
	end

	ui.renderer = renderer
	ui.view = view
end

---@param ui AtlasDiffUI
local function setup_ui(ui)
	local session = ui.session
	local options = ui.options
	local view = ui.view
	local explorer_options = options.explorer
	---@cast explorer_options AtlasPullsDiffExplorerConfig

	vim.cmd.tcd(vim.fn.fnameescape(session.range.root))

	ui.commits = commits.create(session.commits, explorer_options.show_commits)
	ui.review_panel = review_panel.create(session, options.review_panel, {
		on_resize = function()
			resize(ui)
		end,
		on_select = function(entry, focus)
			open_review_item(ui, entry, focus)
		end,
		on_action = function(id, target)
			actions.dispatch(id, {
				session = session,
				comment = target.comment,
				note = target.note,
				review_entry = target.review_entry,
				pending = target.pending,
			}, function()
				update_review(ui)
			end)
		end,
	})
	ui.explorer = explorer.create({
		files = session.files,
		options = explorer_options,
		reviewed_files = session.reviewed_files,
		review_data = session.review,
		notes = session.notes and session.notes.items,
		on_select = function(file, focus)
			select_file(ui, file, focus)
		end,
	})

	if session.source.kind == "pr" and not options.review_panel.hidden then
		review_panel.open(ui.review_panel)
	end
	if ui.commits.shown and ui.explorer.win then
		commits.open(ui.commits, ui.explorer.win)
	end
	resize(ui)

	setup_autocmds(ui)
	setup_keymaps(ui)

	diff_statusline.update(ui)
	for _, pane in pairs({ view.left, view.right, ui.explorer, ui.commits, ui.review_panel }) do
		ui.statusline:attach(pane.win)
	end

	local focus_win = explorer_options.initial_focus == "explorer" and ui.explorer.win or view.right.win
	vim.api.nvim_set_current_win(focus_win)

	local first = ui.explorer.files[1]
	if first then
		select_file(ui, first)
	end
end

---@param session AtlasDiffSession
---@param options AtlasPullsDiffConfig
---@return AtlasDiffUI|nil
function M.open(session, options)
	local module = renderers[options.open_cmd]
	if not module then
		local opened, err = open_command(session, options.open_cmd)
		if opened then
			return
		end

		fallback(session, options, err)
		module = renderers.AtlasDiff
	end

	local ui = {
		session = session,
		options = options,
		statusline = statusline.new({ context = "diff" }),
	}
	---@cast ui AtlasDiffUI

	open_view(ui, module)

	local opened, err = pcall(setup_ui, ui)
	if not opened then
		close(ui)
		error(err, 0)
	end

	ui.id = events.new_id(renderers[options.open_cmd]:match("[^.]+$"))
	emit_event(ui, "AtlasDiffOpened")
	-- The first file may already be loaded during setup.
	if ui.view.current_file then
		emit_event(ui, "AtlasDiffFileChanged")
	end

	return ui
end

return M
