local events = require("atlas.core.events")
local logger = require("atlas.core.logger")
local notify = require("atlas.core.notify")
local request_scope = require("atlas.core.requests")
local providers = require("atlas.providers")
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

local M = {}

-- Those are the only supported renderer for now. Other commands will simply just open the diff with no built-in stuff.
local renderers = {
	AtlasDiff = "atlas.pulls.diff.atlas",
	CodeDiff = "atlas.pulls.diff.codediff",
	DiffviewOpen = "atlas.pulls.diff.diffview",
}

---@class AtlasDiffView
---@field tabpage integer
---@field result AtlasDiffResult
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
---@field open fun(result: AtlasDiffResult, callbacks: AtlasDiffCallbacks): AtlasDiffView
---@field show_file fun(view: AtlasDiffView, file: AtlasDiffFile, on_done: fun(err?: string))
---@field redraw fun(view: AtlasDiffView)
---@field get_selection fun(view: AtlasDiffView): AtlasDiffSelection|nil, string|nil
---@field navigate_annotation fun(view: AtlasDiffView, direction: 1|-1, kind: "comment"|"note", from_edge?: boolean): boolean
---@field resize fun(view: AtlasDiffView)
---@field setup_keymaps fun(session: AtlasDiffSession, actions: AtlasDiffKeymapActions, groups: AtlasDiffKeymapGroup[])
---@field dispose fun(view: AtlasDiffView)

---@class AtlasDiffSession
---@field id string|nil
---@field data AtlasDiffResult
---@field renderer AtlasDiffRenderer
---@field view AtlasDiffView
---@field explorer AtlasDiffExplorer
---@field commits { buf: integer, win?: integer, shown: boolean, items: PullsCommit[], cursor_row: integer, group: integer }
---@field review_panel AtlasDiffReviewPanel
---@field reviewed_files table<string, boolean>
---@field requests table<string, AtlasRequestScope>
---@field statusline AtlasStatusline
---@field group integer|nil
---@field closed boolean

---@param session AtlasDiffSession
---@param name string
---@param reason string|nil
local function emit_event(session, name, reason)
	local result = session.data
	local file = session.view.current_file
	events.emit(name, {
		session_id = session.id,
		viewer = renderers[result.options.open_cmd]:match("[^.]+$"),
		tabpage = session.view.tabpage,
		root = result.root,
		base_revision = result.base_revision,
		head_revision = result.head_revision,
		path = file and file.path,
		status = file and file.status,
		reason = reason,
	})
end

local function close_tab(tabpage)
	if #vim.api.nvim_list_tabpages() == 1 then
		vim.cmd.tabnew()
		vim.wo.statusline = vim.go.statusline
	end

	vim.cmd.tabclose({ range = { vim.api.nvim_tabpage_get_number(tabpage) } })
end

---@param result AtlasDiffResult
---@return boolean, string|nil
local function open_command(result)
	vim.cmd.tabnew()
	local tabpage = vim.api.nvim_get_current_tabpage()

	local opened, err = pcall(function()
		vim.bo.bufhidden = "wipe"
		vim.bo.buflisted = false
		vim.wo.statusline = vim.go.statusline
		vim.wo.statuscolumn = vim.go.statuscolumn
		vim.wo.winbar = vim.go.winbar

		vim.cmd.tcd(vim.fn.fnameescape(result.root))
		vim.api.nvim_cmd({
			cmd = result.options.open_cmd,
			args = { result.base_revision .. "..." .. result.head_revision },
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

	result.release()
	return true
end

---@param session AtlasDiffSession
---@param reason string|nil
local function close(session, reason)
	if session.closed then
		return
	end

	session.closed = true
	for _, pending in pairs(session.requests) do
		pending.cancel()
	end

	if session.group then
		vim.api.nvim_del_augroup_by_id(session.group)
	end

	annotations.close(session.view.tabpage)
	session.statusline:dispose()
	if vim.api.nvim_tabpage_is_valid(session.view.tabpage) then
		close_tab(session.view.tabpage)
	end
	session.renderer.dispose(session.view)

	if session.commits then
		commits.dispose(session.commits)
	end
	if session.review_panel then
		review_panel.dispose(session.review_panel)
	end
	if session.explorer then
		explorer.dispose(session.explorer)
	end

	session.data.release()

	if not session.id then
		return
	end

	emit_event(session, "AtlasDiffClosed", reason or "viewer_closed")
end

---@param session AtlasDiffSession
---@param file AtlasDiffFile
---@param focus boolean|nil
---@param on_done (fun())|nil
local function select_file(session, file, focus, on_done)
	if session.closed then
		return
	end

	explorer.reveal(session.explorer, file)
	session.renderer.show_file(session.view, file, function(err)
		if err then
			logger.logerror("diff.show_file failed", {
				command = session.data.options.open_cmd,
				root = session.data.root,
				base = session.data.base_revision,
				head = session.data.head_revision,
				path = file.path,
				error = err,
			})
			notify.error("Unable to open " .. file.path .. "\n\n" .. err, { vim_notify = true })
			explorer.reveal(session.explorer, session.view.current_file)
			return
		end

		if focus and vim.api.nvim_get_current_win() == session.explorer.win then
			vim.api.nvim_set_current_win(session.view.right.win)
		end
		if on_done then
			on_done()
		end
	end)
end

---@param session AtlasDiffSession
local function update_panels(session)
	local result = session.data
	explorer.update(
		session.explorer,
		result.review and session.reviewed_files,
		result.review and result.review.data,
		result.notes and result.notes.items
	)
	review_panel.render(session.review_panel)
	diff_statusline.update(session)
end

---@param session AtlasDiffSession
local function update_review(session)
	session.renderer.redraw(session.view)
	update_panels(session)
end

---@param session AtlasDiffSession
local function show_details(session)
	local file = session.view.current_file
	local by_line = session.view.annotations[vim.api.nvim_get_current_buf()]
	local items = by_line and by_line[vim.api.nvim_win_get_cursor(0)[1]]
	if not file or not items then
		vim.lsp.buf.hover()
		return
	end

	annotations.open(session.view.tabpage, session.data, file.path, items, function(action, target, on_submit)
		---@type AtlasDiffActionContext
		local context = {
			session = session,
			comment = target.comment,
			note = target.note,
			pending = target.pending,
			on_submit = on_submit,
		}
		actions.dispatch(action, context, function()
			update_review(session)
		end)
	end)
end

---@param session AtlasDiffSession
---@param action "delete_comment"|"toggle_resolved"
local function dispatch_annotation(session, action)
	local by_line = session.view.annotations[vim.api.nvim_get_current_buf()]
	local items = by_line and by_line[vim.api.nvim_win_get_cursor(0)[1]]
	if not items or #items == 0 then
		return
	end
	if #items > 1 then
		show_details(session)
		return
	end

	local item = items[1]
	---@type AtlasDiffActionContext
	local context = { session = session }
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
		update_review(session)
	end)
end

---@param session AtlasDiffSession
---@param direction 1|-1
---@param unreviewed_only boolean|nil
local function navigate_file(session, direction, unreviewed_only)
	local files = session.explorer.files
	if #files == 0 then
		return
	end

	local position = explorer.current_index(session.explorer) or 1
	local steps = unreviewed_only and #files - 1 or 1

	for offset = 1, steps do
		local file = files[((position - 1 + direction * offset) % #files) + 1]
		if not unreviewed_only or not session.reviewed_files[file.path] then
			select_file(session, file)
			return
		end
	end

	notify.info("No other unreviewed files")
end

---@param session AtlasDiffSession
---@param direction 1|-1
---@param kind "comment"|"note"
local function navigate_annotation(session, direction, kind)
	if session.renderer.navigate_annotation(session.view, direction, kind) then
		return
	end

	local files = session.explorer.files
	local index = direction == 1 and 0 or 1
	for position, file in ipairs(files) do
		if file == session.view.current_file then
			index = position
			break
		end
	end

	local field = kind == "comment" and "thread" or "note"
	for offset = 1, #files do
		local file = files[((index - 1 + direction * offset) % #files) + 1]
		local items = annotations.for_file(session.data, file)
		if vim.iter(items):any(function(item)
			return item[field] ~= nil
		end) then
			select_file(session, file, nil, function()
				session.renderer.navigate_annotation(session.view, direction, kind, true)
			end)
			return
		end
	end
end

---@param session AtlasDiffSession
---@return AtlasDiffFile|nil
local function current_file(session)
	if vim.api.nvim_get_current_buf() == session.explorer.buf then
		return explorer.current_file(session.explorer)
	end
	return session.view.current_file
end

---@param session AtlasDiffSession
local function toggle_file_reviewed(session)
	local result = session.data
	if not result.review then
		return
	end

	local file = current_file(session)
	if not file or session.requests[file.path] then
		return
	end

	local reviewed = not session.reviewed_files[file.path]
	local files = session.explorer.files
	local next_file
	for index, item in ipairs(files) do
		if item == file then
			next_file = files[index % #files + 1]
			break
		end
	end

	session.reviewed_files[file.path] = reviewed or nil
	update_panels(session)

	if next_file and next_file ~= file then
		select_file(session, next_file)
	else
		explorer.reveal(session.explorer, file)
	end

	local pr = result.pr
	---@cast pr PullRequest
	local provider = providers.load(pr.provider, "pulls")
	---@cast provider PullsProvider
	local reviews = provider.capabilities.reviews
	if not reviews or not reviews.set_file_reviewed then
		return
	end

	local pending = request_scope.new()
	session.requests[file.path] = pending
	pending.run(function(done)
		return reviews.set_file_reviewed(pr, file.path, reviewed, done)
	end, function(ok, err)
		session.requests[file.path] = nil
		if ok then
			return
		end

		logger.logerror("diff.set_file_reviewed failed", {
			provider = pr.provider,
			repo = pr.repo_full_name,
			pr_id = pr.id,
			path = file.path,
			error = err,
		})
		local message = "Unable to update reviewed file" .. (err and "\n\n" .. err or "")
		notify.error(message, { vim_notify = true })
	end)
end

---@param session AtlasDiffSession
local function find_file(session)
	picker.select({
		title = "Changed files",
		items = session.explorer.files,
		initial_index = explorer.current_index(session.explorer),
		format_item = function(file)
			return file.path
		end,
		on_select = function(file)
			if file then
				select_file(session, file)
			end
		end,
	})
end

---@param session AtlasDiffSession
local function resize(session)
	-- Closing the whole tab also queues the review panel's resize callback.
	if not vim.api.nvim_win_is_valid(session.view.right.win) then
		return
	end

	explorer.resize(session.explorer)
	commits.resize(session.commits, session.explorer.win)
	session.renderer.resize(session.view)
end

---@param session AtlasDiffSession
local function focus_explorer(session)
	if not session.explorer.win then
		local win = explorer.toggle(session.explorer)
		session.statusline:attach(win)
		resize(session)
	end

	vim.api.nvim_set_current_win(session.explorer.win)
end

---@param session AtlasDiffSession
local function toggle_explorer(session)
	if session.explorer.win then
		commits.close(session.commits)
	end

	local win = explorer.toggle(session.explorer)
	if win then
		session.statusline:attach(win)
		if session.commits.shown then
			local commits_win = commits.open(session.commits, win)
			session.statusline:attach(commits_win)
		end
	end
	resize(session)
end

---@param session AtlasDiffSession
local function toggle_commits(session)
	if session.commits.win then
		session.commits.shown = false
		commits.close(session.commits)
		return
	end

	if not session.explorer.win and #session.commits.items > 0 then
		local win = explorer.toggle(session.explorer)
		session.statusline:attach(win)
		resize(session)
	end

	local win, err = commits.open(session.commits, session.explorer.win)
	if not win then
		---@cast err string
		notify.info(err)
		return
	end

	session.commits.shown = true
	session.statusline:attach(win)
	vim.api.nvim_set_current_win(win)
end

---@param session AtlasDiffSession
local function toggle_review_panel(session)
	local panel = session.review_panel
	if panel.win then
		review_panel.close(panel)
		return
	end

	local win = review_panel.open(panel)
	session.statusline:attach(win)
	vim.api.nvim_set_current_win(win)
end

---@param session AtlasDiffSession
---@param entry AtlasDiffReviewPanelRow
---@param focus boolean
local function open_review_item(session, entry, focus)
	local comment = entry.thread_root or entry.comment
	local position = comment and (comment.file or comment.inline)
	local path = entry.note and entry.note.file_path or position and position.path
	if not path then
		return
	end

	local file = vim.iter(session.data.files):find(function(item)
		return item.path == path or item.old_path == path
	end)
	if not file then
		notify.info("File is not in this diff")
		return
	end

	select_file(session, file, false, function()
		if focus then
			vim.api.nvim_set_current_win(session.view.right.win)
		end
		annotations.jump(session.view, { comment = comment, note = entry.note }, focus)
	end)
end

---@param session AtlasDiffSession
local function setup_autocmds(session)
	local view = session.view
	session.group = vim.api.nvim_create_augroup("AtlasDiff" .. view.tabpage, { clear = true })

	vim.api.nvim_create_autocmd({ "LspAttach", "LspDetach" }, {
		group = session.group,
		-- Let Neovim finish updating the buffer's attached clients.
		callback = vim.schedule_wrap(function(event)
			if not session.closed and event.buf == view.right.buf then
				diff_statusline.update(session)
			end
		end),
	})

	vim.api.nvim_create_autocmd("VimResized", {
		group = session.group,
		callback = function()
			review_panel.resize(session.review_panel)
			resize(session)
		end,
	})

	vim.api.nvim_create_autocmd("TabClosed", {
		group = session.group,
		callback = function()
			if not vim.api.nvim_tabpage_is_valid(view.tabpage) then
				close(session, "tab_closed")
			end
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = session.group,
		callback = vim.schedule_wrap(function(event)
			local win = tonumber(event.match)
			if win == view.right.win or win == view.left.win then
				close(session, "window_closed")
				return
			end
			if not session.explorer.win and session.commits.win then
				commits.close(session.commits)
			end
		end),
	})
end

---@param session AtlasDiffSession
local function setup_keymaps(session)
	local result = session.data
	local view = session.view
	local function on_review_updated()
		update_review(session)
	end

	keymaps.setup(session, {
		close = function()
			close(session, "user_close")
		end,
		reload = function()
			local diff = require("atlas.pulls.diff")
			if result.pr then
				diff.open_pr({
					provider = result.pr.provider,
					repo_full_name = result.pr.repo_full_name,
					id = result.pr.id,
					root = result.root,
				})
			elseif result.kind == "commit" then
				diff.open_commit({ commit = result.head_ref, root = result.root })
			else
				diff.open_range({ base = result.base_ref, head = result.head_ref, root = result.root })
			end

			close(session, "refresh")
		end,
		toggle_explorer = function()
			toggle_explorer(session)
		end,
		toggle_commits = function()
			toggle_commits(session)
		end,
		toggle_review_panel = function()
			toggle_review_panel(session)
		end,
		toggle_file_reviewed = function()
			toggle_file_reviewed(session)
		end,
		toggle_resolved = function()
			dispatch_annotation(session, "toggle_resolved")
		end,
		delete_annotation = function()
			dispatch_annotation(session, "delete_comment")
		end,
		toggle_comments = function()
			local options = result.options
			options.comment_display = options.comment_display == "virtual_lines" and "virtual_text" or "virtual_lines"
			session.renderer.redraw(view)
		end,
		toggle_threads = function(all)
			if not annotations.toggle_threads(view, all) then
				return false
			end

			session.renderer.redraw(view)
			return true
		end,
		add_comment = function(pending, suggestion)
			if vim.api.nvim_get_current_buf() == session.explorer.buf then
				local file = explorer.current_file(session.explorer)
				if file then
					actions.dispatch("add_comment", {
						session = session,
						file = file,
						pending = pending,
					}, on_review_updated)
				end
				return
			end

			local selection, err = session.renderer.get_selection(view)
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
			local selection, err = session.renderer.get_selection(view)
			if not selection then
				if err then
					notify.info(err)
				end
				return
			end

			actions.dispatch("add_note", { session = session, selection = selection }, on_review_updated)
		end,
		navigate_annotation = function(direction, kind)
			navigate_annotation(session, direction, kind)
		end,
		dispatch = function(id)
			actions.dispatch(id, { session = session }, on_review_updated)
		end,
		run_custom = function(callback)
			return actions.run_custom(callback, { session = session }, on_review_updated)
		end,
		navigate_file = function(direction, unreviewed_only)
			navigate_file(session, direction, unreviewed_only)
		end,
		find_file = function()
			find_file(session)
		end,
		open_file = function()
			local file = current_file(session)
			if not file then
				return
			end

			local path = vim.fs.joinpath(result.root, file.path)
			if vim.fn.filereadable(path) ~= 1 then
				notify.warn("File not found")
				return
			end

			vim.cmd.tabedit({ args = { path } })
			local options = vim.wo[0][0]
			options.statusline = vim.go.statusline
			options.winbar = vim.go.winbar
			options.winhighlight = vim.go.winhighlight
		end,
		open_commit = function()
			local commit = commits.current(session.commits)
			if not commit then
				return
			end

			require("atlas.pulls.diff").open_commit({ commit = commit.hash, root = result.root })
		end,
		focus_explorer = function()
			focus_explorer(session)
		end,
	})
end

---@param result AtlasDiffResult
---@param err any
local function fallback(result, err)
	local command = result.options.open_cmd
	logger.logwarn("diff.open fallback", {
		command = command,
		kind = result.kind,
		provider = result.pr and result.pr.provider,
		repo = result.pr and result.pr.repo_full_name,
		pr_id = result.pr and result.pr.id,
		root = result.root,
		base = result.base_revision,
		head = result.head_revision,
		error = tostring(err),
	})
	notify.warn(command .. " failed to open. Opening Atlas instead.", { vim_notify = true })
	result.options.open_cmd = "AtlasDiff"
end

---@param session AtlasDiffSession
---@param module string
local function open_view(session, module)
	local result = session.data
	local callbacks = {
		on_file = function(file)
			local changed = session.view.current_file ~= file
			session.view.current_file = file
			winbar.update(session.view)
			diff_statusline.update(session)
			if session.explorer.selected ~= file then
				explorer.reveal(session.explorer, file)
			end

			setup_keymaps(session)
			for _, pane in pairs({ session.view.left, session.view.right }) do
				session.statusline:attach(pane.win)
			end

			if changed and session.id then
				emit_event(session, "AtlasDiffFileChanged")
			end
		end,
		show_details = function()
			show_details(session)
		end,
	}

	---@type AtlasDiffRenderer
	local renderer
	local view_opened, view = pcall(function()
		renderer = require(module)
		return renderer.open(result, callbacks)
	end)

	if not view_opened then
		if result.options.open_cmd == "AtlasDiff" then
			error(view, 0)
		end

		fallback(result, view)
		renderer = atlas
		view = renderer.open(result, callbacks)
	end

	session.renderer = renderer
	session.view = view
end

---@param session AtlasDiffSession
local function setup_ui(session)
	local result = session.data
	local view = session.view
	local explorer_options = result.options.explorer
	---@cast explorer_options AtlasPullsDiffExplorerConfig

	vim.cmd.tcd(vim.fn.fnameescape(result.root))

	session.commits = commits.create(result.commits, explorer_options.show_commits)
	session.review_panel = review_panel.create(result, {
		on_resize = function()
			resize(session)
		end,
		on_select = function(entry, focus)
			open_review_item(session, entry, focus)
		end,
		on_action = function(id, target)
			actions.dispatch(id, {
				session = session,
				comment = target.comment,
				note = target.note,
				review_entry = target.review_entry,
				pending = target.pending,
			}, function()
				update_review(session)
			end)
		end,
	})
	session.explorer = explorer.create({
		files = result.files,
		options = explorer_options,
		reviewed_files = result.review and session.reviewed_files,
		review_data = result.review and result.review.data,
		notes = result.notes and result.notes.items,
		on_select = function(file, focus)
			select_file(session, file, focus)
		end,
	})

	if not result.options.review_panel.hidden then
		review_panel.open(session.review_panel)
	end
	if session.commits.shown and session.explorer.win then
		commits.open(session.commits, session.explorer.win)
	end
	resize(session)

	setup_autocmds(session)
	setup_keymaps(session)

	diff_statusline.update(session)
	for _, pane in pairs({ view.left, view.right, session.explorer, session.commits, session.review_panel }) do
		session.statusline:attach(pane.win)
	end

	local focus_win = explorer_options.initial_focus == "explorer" and session.explorer.win or view.right.win
	vim.api.nvim_set_current_win(focus_win)

	local first = session.explorer.files[1]
	if first then
		select_file(session, first)
	end
end

---@param result AtlasDiffResult
---@return AtlasDiffSession|nil
function M.open(result)
	local module = renderers[result.options.open_cmd]
	if not module then
		local opened, err = open_command(result)
		if opened then
			return
		end

		fallback(result, err)
		module = renderers.AtlasDiff
	end

	local review_context = result.review and result.review.context
	local session = {
		data = result,
		statusline = statusline.new(),
		reviewed_files = vim.deepcopy(review_context and review_context.reviewed_files or {}),
		requests = {},
		closed = false,
	}
	---@cast session AtlasDiffSession

	open_view(session, module)

	local opened, err = pcall(setup_ui, session)
	if not opened then
		close(session)
		error(err, 0)
	end

	local viewer = renderers[result.options.open_cmd]:match("[^.]+$")
	session.id = events.new_id(viewer)
	emit_event(session, "AtlasDiffOpened")
	-- The first file may already be loaded during setup.
	if session.view.current_file then
		emit_event(session, "AtlasDiffFileChanged")
	end

	return session
end

return M
