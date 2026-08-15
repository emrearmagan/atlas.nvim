local M = {}

local commits = require("atlas.pulls.diff.atlas.commits")
local comments = require("atlas.pulls.diff.comments")
local config = require("atlas.config")
local events = require("atlas.core.events")
local explorer = require("atlas.pulls.diff.atlas.explorer")
local git = require("atlas.pulls.diff.atlas.git")
local keymaps = require("atlas.pulls.diff.atlas.keymaps")
local logger = require("atlas.core.logger")
local notes = require("atlas.pulls.diff.notes")
local position = require("atlas.pulls.diff.position")
local pulls_highlights = require("atlas.pulls.ui.highlights")
local review_panel = require("atlas.pulls.diff.ui.review_panel")
local review = require("atlas.pulls.diff.review")
local session_api = require("atlas.pulls.diff.session")
local shared_highlights = require("atlas.ui.shared.highlights")
local statusline = require("atlas.pulls.diff.ui.statusline")
local view = require("atlas.pulls.diff.atlas.view")

---@param session AtlasDiffSession
---@param reason string|nil
---@return table
local function event_data(session, reason)
	local lifecycle = session.viewer_state.lifecycle
	local data = {
		session_id = lifecycle and lifecycle.session_id or session.id,
		viewer = "atlas",
		tabpage = session.tabpage,
		root = session.source.root,
		base_revision = session.source.base_revision,
		head_revision = session.source.head_revision,
	}
	if reason then
		data.reason = reason
	end
	return data
end

---@param session AtlasDiffSession
---@param reason string
local function emit_closed(session, reason)
	local lifecycle = session.viewer_state.lifecycle
	if lifecycle.opened and not lifecycle.closed then
		lifecycle.closed = true
		events.emit("AtlasDiffClosed", event_data(session, reason))
	end
end

---@param session AtlasDiffSession
local function cancel_job(session)
	local state = session.viewer_state --[[@as AtlasNativeDiffState]]
	if state.job then
		state.job.cancel()
		state.job = nil
	end
end

---@param session AtlasDiffSession
---@param index integer
---@param on_loaded (fun(document: AtlasDiffDocument))|nil
local function select_file(session, index, on_loaded)
	local state = session.viewer_state --[[@as AtlasNativeDiffState]]
	if state.closing or not state.files[index] then
		return
	end
	cancel_job(session)
	explorer.reveal_file(session, index)
	state.pending_index = index
	explorer.render(session, state.annotated_paths)
	state.job = git.document(state.range, state.files[index], function(document, err)
		if state.closing then
			return
		end
		state.job = nil
		if not document then
			state.pending_index = nil
			explorer.render(session, state.annotated_paths)
			local message = tostring(err or "Unable to load file diff")
			logger.logerror("diff.file failed", { path = state.files[index].path, error = message })
			session_api.notify(session, "error", message)
			return
		end
		state.selected_index = index
		state.pending_index = nil
		view.set_document(session, document)
		session_api.set_current(session, view.current(session))
		if on_loaded then
			on_loaded(document)
		end
	end)
end

---@param session AtlasDiffSession
---@param path string
---@return integer|nil
local function file_index(session, path)
	---@type DiffFile[]
	local files = session.viewer_state.files
	for index, file in ipairs(files) do
		if file.path == path or file.old_path == path then
			return index
		end
	end
	return nil
end

---@param session AtlasDiffSession
---@param index integer
---@param callback fun(document: AtlasDiffDocument)
local function with_file(session, index, callback)
	local state = session.viewer_state --[[@as AtlasNativeDiffState]]
	if index == state.selected_index and not state.pending_index then
		callback(state.document)
	else
		select_file(session, index, callback)
	end
end

---@param win integer
---@param line integer
---@param focus_diff boolean
local function reveal_line(win, line, focus_diff)
	vim.api.nvim_win_set_cursor(win, { line, 0 })
	vim.api.nvim_win_call(win, function()
		pcall(vim.cmd.normal, { "zvzz", bang = true })
	end)
	if focus_diff then
		vim.api.nvim_set_current_win(win)
	end
end

---@param session AtlasDiffSession
---@param item AtlasDiffReviewPanelSelection
---@param focus_diff boolean
local function focus_item(session, item, focus_diff)
	local comment = item.comment
	local note = item.note
	local target = comment and (comment.file or comment.inline) or nil
	local path = note and note.file_path or (target and (target.path or target.old_path))
	local index = path and file_index(session, path) or nil
	if not index then
		session_api.notify(session, "info", "This review item's file is no longer in the diff")
		return
	end
	with_file(session, index, function(document)
		---@type AtlasDiffSide|nil
		local side = note and "RIGHT" or nil
		local line = note and note.line or nil
		if note then
			if document.binary or document.status == "deleted" then
				session_api.notify(session, "info", "This note's file is no longer in the diff")
				return
			end
		else
			side, line = position.comment(document, comment)
		end
		if not side or not line then
			session_api.notify(session, "info", "This review item no longer has a diff position")
			return
		end

		local current = view.current(session)
		local target = side == "LEFT" and current.left or current.right
		if side == "LEFT" and current.layout == "inline" then
			target = current.right
			line = position.opposite_line(document, "LEFT", line, vim.api.nvim_buf_line_count(current.right.buf))
		end
		if not target.win or not vim.api.nvim_win_is_valid(target.win) or line < 1 then
			session_api.notify(session, "info", "This review item's diff position is outdated")
			return
		end
		line = math.min(line, vim.api.nvim_buf_line_count(target.buf))
		session:render()
		reveal_line(target.win, line, focus_diff)
	end)
end

---@param session AtlasDiffSession
---@param index integer
---@param direction 1|-1
---@return integer|nil
local function unreviewed_file(session, index, direction)
	local order = explorer.ordered_indices(session)
	local position_in_order = 1
	for current, ordered_index in ipairs(order) do
		if ordered_index == index then
			position_in_order = current
			break
		end
	end
	for offset = 1, #order - 1 do
		local candidate = order[((position_in_order - 1 + direction * offset) % #order) + 1]
		if not session.reviewed_files[session.viewer_state.files[candidate].path] then
			return candidate
		end
	end
	return nil
end

---@param session AtlasDiffSession
local function toggle_file_reviewed(session)
	local state = session.viewer_state --[[@as AtlasNativeDiffState]]
	local index = explorer.file_at_cursor(session) or state.selected_index
	local file = state.files[index]
	if not file then
		return
	end
	local reviewed = not session.reviewed_files[file.path]
	local current_review = session.review
	local reviews = current_review and current_review.provider.capabilities.reviews
	local context
	if reviews and reviews.set_file_reviewed then
		context = review.action_context(session)
	end

	local next_index = reviewed and unreviewed_file(session, index, 1) or nil
	session.reviewed_files[file.path] = reviewed or nil
	if next_index then
		select_file(session, next_index)
		index = next_index
	else
		explorer.render(session, state.annotated_paths)
	end
	local line = explorer.line_for_file(session, index)
	if line and state.panel.win and vim.api.nvim_win_is_valid(state.panel.win) then
		vim.api.nvim_win_set_cursor(state.panel.win, { line, 0 })
	end

	if not context then
		return
	end
	reviews.set_file_reviewed(current_review.pr, file.path, reviewed, function(ok, err)
		if not ok then
			session_api.notify(session, "error", "Unable to update reviewed file: " .. tostring(err))
		end
	end)
end

---@param session AtlasDiffSession
---@param direction 1|-1
local function navigate_unreviewed_file(session, direction)
	local state = session.viewer_state --[[@as AtlasNativeDiffState]]
	local current = explorer.file_at_cursor(session) or state.pending_index or state.selected_index
	local target = unreviewed_file(session, current, direction)
	if not target then
		session_api.notify(session, "info", "No other unreviewed files")
		return
	end
	select_file(session, target)
	local line = explorer.line_for_file(session, target)
	if line and state.panel.win and vim.api.nvim_win_is_valid(state.panel.win) then
		vim.api.nvim_win_set_cursor(state.panel.win, { line, 0 })
	end
end

---@param session AtlasDiffSession
---@param direction 1|-1
local function navigate_file(session, direction)
	local state = session.viewer_state --[[@as AtlasNativeDiffState]]
	local order = explorer.ordered_indices(session)
	if #order == 0 then
		return
	end
	local current = state.pending_index or state.selected_index
	local current_position = 1
	for index, ordered_index in ipairs(order) do
		if ordered_index == current then
			current_position = index
			break
		end
	end
	local target = order[((current_position - 1 + direction) % #order) + 1]
	select_file(session, target)
	local line = explorer.line_for_file(session, target)
	if line and state.panel.win and vim.api.nvim_win_is_valid(state.panel.win) then
		vim.api.nvim_win_set_cursor(state.panel.win, { line, 0 })
	end
end

---@param session AtlasDiffSession
---@param direction 1|-1
local function navigate_hunk(session, direction)
	local state = session.viewer_state --[[@as AtlasNativeDiffState]]
	if #state.document.changes == 0 then
		session_api.notify(session, "info", "No diff hunks in this file")
		return
	end
	local use_left = vim.api.nvim_get_current_buf() == state.left.buf
	local target = use_left and state.left or state.right
	if not target.win or not vim.api.nvim_win_is_valid(target.win) then
		return
	end
	local line_count = vim.api.nvim_buf_line_count(target.buf)
	local lines = {}
	for _, hunk in ipairs(state.document.changes) do
		local start = use_left and hunk.old_start or hunk.new_start
		lines[#lines + 1] = math.max(1, math.min(line_count, start))
	end
	table.sort(lines)
	vim.api.nvim_set_current_win(target.win)
	local cursor = vim.api.nvim_win_get_cursor(target.win)[1]
	local destination = direction > 0 and lines[1] or lines[#lines]
	for _, line in ipairs(lines) do
		if direction > 0 and line > cursor then
			destination = line
			break
		elseif direction < 0 and line < cursor then
			destination = line
		end
	end
	vim.api.nvim_win_set_cursor(target.win, { destination, 0 })
	vim.cmd.normal({ "zvzz", bang = true })
end

---@param session AtlasDiffSession
local function reload(session)
	local target = view.replace_with_loading(session)
	if not target then
		return
	end
	target.on_abandon = function(reason)
		emit_closed(session, reason)
	end
	M.detach(session, "reload")
	if session.reload then
		session.reload(target)
	end
end

---@param session AtlasDiffSession
local function register_keymaps(session)
	keymaps.register(session, {
		close = function()
			M.detach(session, "user_close")
		end,
		reload = function()
			reload(session)
		end,
		refresh_review = function()
			review.reload(session)
			notes.reload(session)
		end,
		toggle_layout = function()
			local current, err = view.toggle_layout(session)
			if current then
				session_api.set_current(session, current)
			else
				session_api.notify(session, "error", err or "Unable to change diff layout")
			end
		end,
		toggle_compact = function()
			local err = view.toggle_compact(session)
			if err then
				session_api.notify(session, "info", err)
			else
				session:render()
			end
		end,
		navigate_hunk = function(direction)
			navigate_hunk(session, direction)
		end,
		navigate_file = function(direction)
			navigate_file(session, direction)
		end,
		navigate_unreviewed_file = function(direction)
			navigate_unreviewed_file(session, direction)
		end,
		toggle_file_reviewed = function()
			toggle_file_reviewed(session)
		end,
		toggle_explorer = function()
			view.toggle_explorer(session)
		end,
		toggle_commits = function()
			view.toggle_commits(session)
		end,
		select_file = function(index, focus_diff)
			select_file(session, index)
			local state = session.viewer_state
			local win = state.right.win or state.left.win
			if focus_diff and win then
				vim.api.nvim_set_current_win(win)
			end
		end,
		show_commit = function()
			commits.show_details(session)
		end,
		add_file_comment = function(pending)
			local state = session.viewer_state --[[@as AtlasNativeDiffState]]
			local index = explorer.file_at_cursor(session)
			local file = index and state.files[index] or nil
			if file then
				comments.add_to_file(session, { path = file.path, old_path = file.old_path }, pending)
			end
		end,
	})
end

---@param session AtlasDiffSession
local function register_events(session)
	local state = session.viewer_state --[[@as AtlasNativeDiffState]]
	state.group = vim.api.nvim_create_augroup("AtlasDiffNative" .. tostring(session.tabpage), { clear = true })
	vim.api.nvim_create_autocmd("TabClosed", {
		group = state.group,
		callback = function()
			vim.schedule(function()
				if not state.closing and session.tabpage and not vim.api.nvim_tabpage_is_valid(session.tabpage) then
					M.detach(session, "tab_closed")
				end
			end)
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = state.group,
		callback = function(args)
			local closed = tonumber(args.match)
			vim.schedule(function()
				if state.closing then
					return
				end
				if closed == state.commits_panel.win then
					state.commits_panel.win = nil
					state.commits_visible = false
				elseif closed == state.panel.win then
					state.panel.win = nil
					view.close_commits(session)
				elseif session.review_panel and closed == session.review_panel.win then
					session.review_panel.win = nil
				elseif closed == state.left.win or closed == state.right.win then
					M.detach(session, "window_closed")
				end
			end)
		end,
	})
	vim.api.nvim_create_autocmd({ "WinResized", "TabEnter" }, {
		group = state.group,
		callback = function()
			vim.schedule(function()
				if state.closing or vim.api.nvim_get_current_tabpage() ~= session.tabpage then
					return
				end
				explorer.configure(session)
				if state.left.win then
					view.configure_content_window(session, state.left.win)
				end
				if state.right.win then
					view.configure_content_window(session, state.right.win)
				end
				view.render_document(session)
				session:render()
			end)
		end,
	})
end

---@param explorer_options AtlasNativeDiffExplorerOptions
---@return AtlasNativeDiffOptions
local function options(explorer_options)
	local diff_config = (config.options.pulls or {}).diff or {}
	return {
		layout = diff_config.layout == "inline" and "inline" or "side-by-side",
		compact = diff_config.compact ~= false,
		compact_context_lines = diff_config.compact_context_lines or 3,
		show_review_panel = diff_config.show_review_panel == true,
		explorer = explorer_options,
	}
end

---@param session AtlasDiffSession
---@param loading_view AtlasLoadingView
---@param on_done fun(err: string|nil)
---@return { cancel: fun() }
function M.open(session, loading_view, on_done)
	shared_highlights.setup()
	pulls_highlights.setup()
	if not session.source.head_revision then
		loading_view:finish()
		on_done("AtlasDiff does not support working-tree diffs yet")
		return { cancel = function() end }
	end
	local explorer_options = explorer.options()
	local cancelled = false
	local request = git.load({
		git_root = session.source.root,
		base_revision = session.source.base_revision,
		head_revision = session.source.head_revision,
		filter = function(files)
			return explorer.filter(files, explorer_options)
		end,
		on_progress = function(message)
			loading_view:update(message)
		end,
	}, function(data, err)
		vim.schedule(function()
			if cancelled then
				return
			end
			if not data then
				loading_view:finish()
				on_done(tostring(err or "Unable to prepare diff"))
				return
			end
			local target = loading_view:handoff()
			if not target then
				on_done("The diff loading view was closed")
				return
			end
			session.source = data.range
			local viewer_options = options(explorer_options)
			local ok, create_err = pcall(view.create, session, data, target, viewer_options)
			if not ok or create_err then
				on_done("Unable to create diff view: " .. tostring(create_err))
				return
			end

			local state = session.viewer_state --[[@as AtlasNativeDiffState]]
			session_api.attach(session, {
				tabpage = state.tabpage,
				notify = function(level, message, duration)
					statusline.notify(session.statusline, level, message, duration)
				end,
				focus_item = function(item, focus_diff)
					focus_item(session, item, focus_diff)
				end,
				render_view = function(output)
					view.render(session, output)
				end,
				toggle_review_panel = function(focus)
					view.toggle_review_panel(session, focus)
				end,
			})
			local panel
			if session.review or session.note_target then
				panel =
					session_api.create_review_panel(session, string.format("atlas-diff://%d/review", session.tabpage))
				review_panel.configure(panel)
			end
			session_api.set_current(session, view.current(session))
			local selected_line = explorer.line_for_file(session, state.selected_index)
			if selected_line and state.panel.win then
				vim.api.nvim_win_set_cursor(state.panel.win, { selected_line, 0 })
			end
			session_api.review_attached(session)
			register_keymaps(session)
			review_panel.register_keymaps(panel)
			register_events(session)
			if panel and viewer_options.show_review_panel then
				view.toggle_review_panel(session, false)
			end
			if not state.lifecycle.opened then
				state.lifecycle.opened = true
				events.emit("AtlasDiffOpened", event_data(session))
			end
			on_done(nil)
		end)
	end)
	return {
		cancel = function()
			cancelled = true
			request.cancel()
		end,
	}
end

---@param session AtlasDiffSession
---@param reason string|nil
function M.detach(session, reason)
	local state = session.viewer_state --[[@as AtlasNativeDiffState]]
	if state.closing then
		return
	end
	state.closing = true
	cancel_job(session)
	if state.group then
		pcall(vim.api.nvim_del_augroup_by_id, state.group)
	end
	session_api.detach(session, reason)
	if reason ~= "reload" and session.tabpage and vim.api.nvim_tabpage_is_valid(session.tabpage) then
		pcall(vim.cmd, vim.api.nvim_tabpage_get_number(session.tabpage) .. "tabclose")
	end
	view.delete_buffers(session)
	if reason ~= "reload" then
		emit_closed(session, reason or "viewer_closed")
	end
end

return M
