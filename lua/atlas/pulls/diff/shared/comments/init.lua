local M = {}

local actions = require("atlas.pulls.actions.review")
local code_preview = require("atlas.ui.components.code_preview")
local renderer = require("atlas.pulls.diff.shared.comments.renderer")
local position = require("atlas.pulls.diff.shared.position")
local comment_threads = require("atlas.ui.components.review_threads")

---@type fun(session: AtlasReviewSession, state: AtlasReviewState)
local reload_review

---@class AtlasReviewState
---@field comments PullsComment[]
---@field tasks PullsComment[]
---@field expanded_threads table<string, boolean>
---@field request_handles { cancel: fun() }[]
---@field provider PullsProvider|nil
---@field pr PullRequest|nil
---@field current_user PullsUser|nil
---@field review_context { authors: PullsAuthor[] }|nil
---@field loading boolean
---@field generation integer

---@param session AtlasReviewSession
---@param level "loading"|"success"|"warn"|"error"|"info"
---@param message string
---@param duration integer|nil
local function view_notify(session, level, message, duration)
	session.review_view.notify(level, message, duration)
end

---@param session AtlasReviewSession
---@param state AtlasReviewState
---@return boolean
local function active(session, state)
	return not session.closing and session.review == state
end

---@param session AtlasReviewSession
---@param state AtlasReviewState
---@param handle { cancel: fun() }|nil
---@return fun()
local function track(session, state, handle)
	if not handle then
		return function() end
	end
	if active(session, state) then
		table.insert(state.request_handles, handle)
	else
		pcall(handle.cancel)
	end
	local tracked = true
	return function()
		if not tracked then
			return
		end
		tracked = false
		for index, candidate in ipairs(state.request_handles) do
			if candidate == handle then
				table.remove(state.request_handles, index)
				break
			end
		end
	end
end

---@param state AtlasReviewState
local function cancel_requests(state)
	local handles = state.request_handles
	state.request_handles = {}
	for _, handle in ipairs(handles) do
		pcall(handle.cancel)
	end
end

---@param state AtlasReviewState
---@param action AtlasReviewCommentAction
---@param comment PullsComment
---@return boolean
local function can_action(state, action, comment)
	return actions.is_available(action, comment, state.current_user, state.provider)
end

---@param session AtlasReviewSession
---@param side "LEFT"|"RIGHT"
---@param line integer
---@return integer line
---@return boolean above
local function opposite_line(session, side, line)
	local target_buf = side == "LEFT" and session.right.buf or session.left.buf
	return position.opposite_line(session.document, side, line, vim.api.nvim_buf_line_count(target_buf))
end

---@param session AtlasReviewSession
---@param state AtlasReviewState
---@return AtlasCommentRendererContext|nil
local function render_context(session, state)
	local document = session.document
	if not document then
		return nil
	end
	local comments = state.provider and state.provider.capabilities.comments
	return {
		threads = comment_threads.group_comments(state.comments, state.tasks),
		expanded_threads = state.expanded_threads,
		old_path = document.old.path,
		new_path = document.new.path,
		reaction_options = comments and comments.reaction_options,
	}
end

---@param session AtlasReviewSession
---@param context AtlasCommentRendererContext
---@param path string
---@param side "LEFT"|"RIGHT"
---@return table<integer, AtlasReviewThreadNode[]>
local function threads_by_line(session, context, path, side)
	local document = session.document
	local target = side == "LEFT" and document.old.lines or document.new.lines
	local result = {}
	for _, node in ipairs(context.threads) do
		local inline = node.comment.inline
		local location_side, location_line = position.location(inline)
		local matches_path = inline and inline.path == path
		if inline and not matches_path and (path == context.old_path or path == context.new_path) then
			matches_path = inline.path == context.old_path or inline.path == context.new_path
		end
		if matches_path and location_side == side and location_line and location_line >= 1 and #target > 0 then
			local line = math.min(location_line, #target)
			result[line] = result[line] or {}
			table.insert(result[line], node)
		end
	end
	return result
end

---@param session AtlasReviewSession
---@param context AtlasCommentRendererContext
---@param path string
---@param side "LEFT"|"RIGHT"
---@return table<integer, AtlasReviewThreadNode[]>
---@return table<integer, boolean> above_lines
local function visible_threads(session, context, path, side)
	local threads = threads_by_line(session, context, path, side)
	local above_lines = {}
	if session.layout ~= "inline" or side ~= "RIGHT" then
		return threads, above_lines
	end
	local old_by_line = threads_by_line(session, context, context.old_path, "LEFT")
	for old_line, old_threads in pairs(old_by_line) do
		local line, above = opposite_line(session, "LEFT", old_line)
		threads[line] = threads[line] or {}
		vim.list_extend(threads[line], old_threads)
		if above then
			above_lines[line] = true
		end
	end
	return threads, above_lines
end

---@param state AtlasReviewState|nil
---@return table<string, boolean>
function M.annotated_paths(state)
	local paths = {}
	for _, comment in ipairs((state and state.comments) or {}) do
		local inline = comment.inline
		if inline then
			paths[inline.path] = true
		end
	end
	return paths
end

---@class AtlasCommentRenderOptions
---@field inline_deleted_lines boolean|nil

---@param session AtlasReviewSession
---@param opts? AtlasCommentRenderOptions
---@return table<integer, [string, string][][]>|nil deleted_comments
function M.render(session, opts)
	local state = session.review
	if not state then
		return
	end
	local context = render_context(session, state)
	if not context then
		return
	end
	local deleted_comments
	local right_threads, right_above
	if opts and opts.inline_deleted_lines and session.layout == "inline" then
		right_threads = threads_by_line(session, context, context.new_path, "RIGHT")
		right_above = {}
		deleted_comments = {}
		local old_threads = threads_by_line(session, context, context.old_path, "LEFT")
		for old_line, old_list in pairs(old_threads) do
			if position.is_changed(session.document, "LEFT", old_line) then
				deleted_comments[old_line] = renderer.thread_lines(context, session.right.buf, old_list)
			else
				local line, above = opposite_line(session, "LEFT", old_line)
				right_threads[line] = right_threads[line] or {}
				vim.list_extend(right_threads[line], old_list)
				if above then
					right_above[line] = true
				end
			end
		end
	else
		right_threads, right_above = visible_threads(session, context, context.new_path, "RIGHT")
	end
	local right = renderer.render_comments(context, session.right.buf, right_threads, {
		above_lines = right_above,
	})
	if session.layout ~= "side-by-side" then
		renderer.clear_comments(session.left.buf)
		return deleted_comments
	end
	local left_threads, left_above = visible_threads(session, context, context.old_path, "LEFT")
	local left = renderer.render_comments(context, session.left.buf, left_threads, {
		above_lines = left_above,
	})
	for line, count in pairs(left) do
		local target, above = opposite_line(session, "LEFT", line)
		renderer.pad_comments(session.right.buf, target, count, left_above[line] or above)
	end
	for line, count in pairs(right) do
		local target, above = opposite_line(session, "RIGHT", line)
		renderer.pad_comments(session.left.buf, target, count, right_above[line] or above)
	end
	return deleted_comments
end

---@param session AtlasReviewSession
---@param buf integer
---@return string|nil, "LEFT"|"RIGHT"|nil
local function buffer_context(session, buf)
	local document = session.document
	if not document then
		return nil, nil
	end
	if buf == session.left.buf then
		return document.old.path, "LEFT"
	end
	if buf == session.right.buf then
		return document.new.path, "RIGHT"
	end
	return nil, nil
end

---@param start_line integer|nil
---@param end_line integer|nil
---@return integer, integer
local function selected_range(start_line, end_line)
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
	start_line, end_line = start_line or cursor_line, end_line or cursor_line
	return math.min(start_line, end_line), math.max(start_line, end_line)
end

---@param session AtlasReviewSession
---@param buf integer
---@param start_line integer|nil
---@param end_line integer|nil
---@return PullsInlineCommentPosition|nil
local function inline_position(session, buf, start_line, end_line)
	local document = session.document
	local _, side = buffer_context(session, buf)
	if not document or not side then
		return nil
	end
	start_line, end_line = selected_range(start_line, end_line)
	local inline = position.from_range(document, side, start_line, end_line)
	if inline then
		inline.commit_hash = session.head_revision
	end
	return inline
end

---@param session AtlasReviewSession
---@param buf integer
---@param selected_start integer|nil
---@param selected_end integer|nil
---@return AtlasMarkdownEditorPreview|nil
local function inline_preview(session, buf, selected_start, selected_end)
	local document = session.document
	local _, side = buffer_context(session, buf)
	if not document or not side or document.binary then
		return nil
	end

	selected_start, selected_end = selected_range(selected_start, selected_end)
	local source = side == "LEFT" and document.old or document.new
	local start_line = math.max(1, selected_start - 2)
	local lines = {}
	for index = start_line, math.min(#source.lines, selected_end + 2) do
		table.insert(lines, source.lines[index])
	end
	return code_preview.render({
		file_path = source.path,
		lines = lines,
		start_line = start_line,
		anchor_start = selected_start,
		anchor_line = selected_end,
	})
end

---@param session AtlasReviewSession
---@param state AtlasReviewState
---@param buf integer
---@return boolean
local function toggle_at_cursor(session, state, buf)
	local path, side = buffer_context(session, buf)
	if not path or not side then
		return false
	end
	local context = render_context(session, state)
	if not context then
		return false
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local threads = visible_threads(session, context, path, side)[line] or {}
	if not comment_threads.toggle_all_threads(threads, state.expanded_threads) then
		return false
	end
	session.refresh_ui()
	return true
end

---@param session AtlasReviewSession
---@param state AtlasReviewState
---@return boolean
local function toggle_all_threads(session, state)
	local review_context = render_context(session, state)
	if not review_context then
		return false
	end
	local roots, seen = {}, {}
	for _, location in ipairs({
		{ path = review_context.old_path, side = "LEFT" },
		{ path = review_context.new_path, side = "RIGHT" },
	}) do
		for _, threads in pairs(visible_threads(session, review_context, location.path, location.side)) do
			for _, thread in ipairs(threads) do
				local key = comment_threads.comment_key(thread.comment)
				if not seen[key] then
					seen[key] = true
					table.insert(roots, thread)
				end
			end
		end
	end
	if not comment_threads.toggle_all_threads(roots, state.expanded_threads) then
		return false
	end
	session.refresh_ui()
	return true
end

---@param session AtlasReviewSession
---@param state AtlasReviewState
---@param buf integer
---@param direction 1|-1
local function jump_comment(session, state, buf, direction)
	local _, current_side = buffer_context(session, buf)
	if not current_side then
		return
	end
	local context = render_context(session, state)
	if not context then
		return
	end

	local sides = session.layout == "inline" and { "RIGHT" }
		or { current_side, current_side == "LEFT" and "RIGHT" or "LEFT" }
	local current_line = vim.api.nvim_win_get_cursor(0)[1]
	local locations = {}
	for side_index, side in ipairs(sides) do
		local path = side == "LEFT" and context.old_path or context.new_path
		local by_line = visible_threads(session, context, path, side)
		local lines = vim.tbl_keys(by_line)
		table.sort(lines)
		if direction < 0 then
			local reversed = {}
			for index = #lines, 1, -1 do
				table.insert(reversed, lines[index])
			end
			lines = reversed
		end
		for _, line in ipairs(lines) do
			if side_index > 1 or (direction > 0 and line > current_line) or (direction < 0 and line < current_line) then
				table.insert(locations, { side = side, line = line })
			end
		end
	end

	if #locations == 0 then
		local path = current_side == "LEFT" and context.old_path or context.new_path
		local by_line = visible_threads(session, context, path, current_side)
		local lines = vim.tbl_keys(by_line)
		table.sort(lines)
		local line = direction > 0 and lines[1] or lines[#lines]
		if line then
			table.insert(locations, { side = current_side, line = line })
		end
	end
	if #locations == 0 then
		view_notify(session, "info", "No comments in this file")
		return
	end

	local target = locations[1]
	local target_win = target.side == "LEFT" and session.left.win or session.right.win
	if not target_win or not vim.api.nvim_win_is_valid(target_win) then
		return
	end
	vim.api.nvim_set_current_win(target_win)
	vim.api.nvim_win_set_cursor(target_win, { target.line, 0 })
	local folded = vim.fn.foldclosed(target.line) ~= -1
	pcall(vim.cmd.normal, { "zv", bang = true })
	if folded and session.layout == "side-by-side" then
		local other_win = target.side == "LEFT" and session.right.win or session.left.win
		if other_win and vim.api.nvim_win_is_valid(other_win) then
			local other_line = opposite_line(session, target.side, target.line)
			vim.api.nvim_win_call(other_win, function()
				local cursor = vim.api.nvim_win_get_cursor(other_win)
				vim.api.nvim_win_set_cursor(other_win, { other_line, 0 })
				pcall(vim.cmd.normal, { "zv", bang = true })
				vim.api.nvim_win_set_cursor(other_win, cursor)
			end)
		end
	end
end

---@param session AtlasReviewSession
---@param state AtlasReviewState
---@param comment PullsComment|nil
---@param after_refresh (fun())|nil
---@return AtlasReviewCommentActionContext|nil
local function action_context(session, state, comment, after_refresh)
	if state.loading or not active(session, state) or not state.provider or not state.pr then
		return nil
	end
	local generation = state.generation
	local provider = state.provider
	local pr = state.pr
	local items = comment and comment.is_task and state.tasks or state.comments
	local comments = provider.capabilities.comments
	local completion = comments
			and comments.comment_completion
			and comments.comment_completion({
				pr = pr,
				comments = state.comments,
				tasks = state.tasks,
				review_context = state.review_context,
			})
		or nil
	return {
		provider = provider,
		pr = pr,
		current_user = state.current_user,
		items = items,
		completion = completion,
		active = function()
			local current_items = comment and comment.is_task and state.tasks or state.comments
			return active(session, state)
				and not state.loading
				and state.generation == generation
				and state.provider == provider
				and state.pr == pr
				and current_items == items
		end,
		track = function(handle)
			return track(session, state, handle)
		end,
		refresh = function()
			if active(session, state) then
				if completion and completion.resolve_items then
					completion.resolve_items()
				end
				session.refresh_ui()
				if after_refresh then
					after_refresh()
				end
			end
		end,
		reload = function()
			if active(session, state) then
				reload_review(session, state)
			end
		end,
		notify = function(level, message, duration)
			if not active(session, state) then
				return
			end
			view_notify(session, level, message, duration)
		end,
	}
end

---@param session AtlasReviewSession
---@param action AtlasReviewCommentAction
---@param comment PullsComment
---@return boolean
function M.is_action_available(session, action, comment)
	local state = session.review
	return state ~= nil and active(session, state) and can_action(state, action, comment)
end

---@param session AtlasReviewSession
---@param action AtlasReviewCommentAction
---@param comment PullsComment
function M.run_action(session, action, comment)
	local state = session.review
	if not state then
		return
	end
	local context = action_context(session, state, comment)
	if context then
		actions.run(context, action, comment)
	end
end

---@param session AtlasReviewSession
---@param state AtlasReviewState
---@param buf integer
---@return AtlasReviewThreadNode[]
local function threads_at_cursor(session, state, buf)
	local path, side = buffer_context(session, buf)
	if not path or not side then
		return {}
	end
	local context = render_context(session, state)
	if not context then
		return {}
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return visible_threads(session, context, path, side)[line] or {}
end

---@param nodes AtlasReviewThreadNode[]
---@return string
local function popup_title(nodes)
	local path, side, line
	for _, node in ipairs(nodes) do
		local inline = node.comment.inline
		if inline then
			local node_side, node_line = position.location(inline)
			if path and (path ~= inline.path or side ~= node_side or line ~= node_line) then
				return " Review threads "
			end
			path, side, line = inline.path, node_side, node_line
		end
	end
	if path and side and line then
		return string.format(" %s:%d (%s) ", path, line, side)
	end
	return " Review thread "
end

---@param session AtlasReviewSession
---@param state AtlasReviewState
---@param buf integer
---@return boolean opened
local function open_thread(session, state, buf)
	local threads = threads_at_cursor(session, state, buf)
	if #threads == 0 then
		return false
	end
	local popup = require("atlas.pulls.diff.shared.comments.popup")
	local owner = tostring(session.tabpage)
	local root_keys = {}
	for _, thread in ipairs(threads) do
		root_keys[comment_threads.comment_key(thread.comment)] = true
	end

	local show
	show = function(nodes)
		local comments = state.provider and state.provider.capabilities.comments
		popup.open({
			nodes = nodes,
			owner = owner,
			title = popup_title(nodes),
			toggle_resolved_keys = require("atlas.core.keymaps").resolve("pulls.review.diff.toggle_resolved"),
			reaction_options = comments and comments.reaction_options,
			can_action = function(action, comment)
				return can_action(state, action, comment)
			end,
			on_action = function(action, comment, close)
				local refresh_popup
				if action == "reply" or action == "edit" then
					refresh_popup = function()
						vim.schedule(function()
							if not active(session, state) or not popup.is_open(owner) then
								return
							end
							local updated = {}
							for _, node in ipairs(comment_threads.group_comments(state.comments, state.tasks)) do
								if root_keys[comment_threads.comment_key(node.comment)] then
									table.insert(updated, node)
								end
							end
							if #updated == 0 then
								popup.close(owner)
								return
							end
							show(updated)
						end)
					end
				end
				local action_ctx = action_context(session, state, comment, refresh_popup)
				if not action_ctx then
					view_notify(session, "warn", "Review actions are not ready")
					return
				end
				if refresh_popup == nil then
					close()
				end
				actions.run(action_ctx, action, comment)
			end,
		})
	end

	show(threads)
	return true
end

---@param session AtlasReviewSession
---@param state AtlasReviewState
---@param buf integer
local function toggle_resolved_at_cursor(session, state, buf)
	local threads = threads_at_cursor(session, state, buf)
	if #threads == 0 then
		view_notify(session, "info", "No thread at cursor")
		return
	end
	if #threads > 1 then
		open_thread(session, state, buf)
		return
	end

	local comment = threads[1].comment
	local action = comment.is_task and "toggle_task" or "toggle_resolved"
	if not can_action(state, action, comment) then
		view_notify(session, "info", "This thread cannot be updated")
		return
	end
	local context = action_context(session, state, comment)
	if context then
		actions.run(context, action, comment)
	end
end

---@param session AtlasReviewSession
---@param state AtlasReviewState
local function toggle_task_at_cursor(session, state)
	local task_at_cursor = session.review_view.task_at_cursor
	if not task_at_cursor then
		return
	end
	local comment = task_at_cursor()
	if not comment then
		return
	end
	if not can_action(state, "toggle_task", comment) then
		view_notify(session, "info", "This task cannot be updated")
		return
	end
	local context = action_context(session, state, comment)
	if context then
		actions.run(context, "toggle_task", comment)
	end
end

---@param session AtlasReviewSession
---@param state AtlasReviewState
---@param buf integer
---@param pending boolean
---@param start_line integer|nil
---@param end_line integer|nil
---@param kind "comment"|"suggestion"
local function add_inline(session, state, buf, pending, start_line, end_line, kind)
	local context = action_context(session, state, nil)
	if not context then
		view_notify(session, "warn", "Review is not ready")
		return
	end
	if kind == "suggestion" and buf ~= session.right.buf then
		view_notify(session, "info", "Suggestions are only available on the new side of the diff")
		return
	end
	start_line, end_line = selected_range(start_line, end_line)
	local inline = inline_position(session, buf, start_line, end_line)
	if not inline then
		return
	end

	---@type AtlasReviewAddOptions
	local opts = { pending = pending, preview = inline_preview(session, buf, start_line, end_line) }
	if kind == "suggestion" then
		local lines = {}
		for line = start_line, end_line do
			table.insert(lines, session.document.new.lines[line])
		end
		local fence = "suggestion"
		if context.provider.id == "gitlab" then
			fence = string.format("suggestion:-%d+0", #lines - 1)
		end
		opts.initial_text = string.format("\n```%s\n%s\n```", fence, table.concat(lines, "\n"))
		opts.kind = "suggestion"
	end
	actions.add(context, inline, opts)
end

---@param session AtlasReviewSession
---@param state AtlasReviewState
---@param buf integer
local function delete_comment_at_cursor(session, state, buf)
	local threads = threads_at_cursor(session, state, buf)
	if #threads == 0 then
		view_notify(session, "info", "No comment at cursor")
		return
	end
	if #threads > 1 then
		open_thread(session, state, buf)
		return
	end

	local comment = threads[1].comment
	if not can_action(state, "delete", comment) then
		view_notify(session, "info", "This comment cannot be deleted")
		return
	end
	local context = action_context(session, state, comment)
	if context then
		actions.run(context, "delete", comment)
	end
end

---@param session AtlasReviewSession
---@param state AtlasReviewState
local function register_keymaps(session, state)
	local toggle_task
	local reviews = state.provider and state.provider.capabilities.reviews
	if reviews and reviews.edit_task and session.review_view.task_at_cursor then
		toggle_task = function()
			toggle_task_at_cursor(session, state)
		end
	end
	local submit_review
	if actions.can_submit(state.provider) then
		submit_review = function()
			local context = action_context(session, state, nil)
			if not context then
				view_notify(session, "warn", "Review is not ready")
				return
			end
			actions.submit(context)
		end
	end
	local toggle_approval
	if state.pr and actions.can_toggle_approval(state.pr) then
		toggle_approval = function()
			local context = action_context(session, state, nil)
			if context then
				actions.toggle_approval(context)
			end
		end
	end
	local request_changes
	if state.pr and actions.can_request_changes(state.pr) then
		request_changes = function()
			local context = action_context(session, state, nil)
			if context then
				actions.request_changes(context)
			end
		end
	end
	session.review_view.register_keymaps({
		active = function()
			return active(session, state)
		end,
		toggle_approval = toggle_approval,
		request_changes = request_changes,
		submit_review = submit_review,
		toggle_task = toggle_task,
		toggle_resolved = function(buf)
			toggle_resolved_at_cursor(session, state, buf)
		end,
		add_comment = function(buf, pending, start_line, end_line)
			add_inline(session, state, buf, pending, start_line, end_line, "comment")
		end,
		add_suggestion = function(buf, pending, start_line, end_line)
			add_inline(session, state, buf, pending, start_line, end_line, "suggestion")
		end,
		delete_comment = function(buf)
			delete_comment_at_cursor(session, state, buf)
		end,
		toggle_thread = function(buf)
			return toggle_at_cursor(session, state, buf)
		end,
		toggle_all_threads = function()
			return toggle_all_threads(session, state)
		end,
		jump_comment = function(buf, direction)
			jump_comment(session, state, buf, direction)
		end,
		open_in_browser = function(buf)
			for _, thread in ipairs(threads_at_cursor(session, state, buf)) do
				local comment = thread.comment
				local url = tostring(comment.html_url or comment.url or "")
				if url ~= "" then
					vim.ui.open(url)
					return
				end
			end
			if state.pr then
				require("atlas.pulls.actions").open_in_browser(state.pr)
			else
				view_notify(session, "warn", "Review is not ready")
			end
		end,
	})
end

---@param session AtlasReviewSession
---@param state AtlasReviewState
---@param context AtlasPreparedReviewContext
local function apply_prepared(session, state, context)
	state.generation = state.generation + 1
	state.current_user = context.current_user
	state.review_context = context.review_context
	state.provider = context.provider
	state.pr = context.pr
	local initial = context.initial_review
	state.comments = vim.deepcopy(initial.comments)
	state.tasks = vim.deepcopy(initial.tasks)
	local comments = context.provider.capabilities.comments
	local completion = comments
			and comments.comment_completion
			and comments.comment_completion({
				pr = context.pr,
				comments = state.comments,
				tasks = state.tasks,
				review_context = state.review_context,
			})
		or nil
	if completion and completion.resolve_items then
		completion.resolve_items()
	end
	state.loading = false
	session.refresh_ui()
	if #initial.warnings > 0 then
		view_notify(session, "warn", table.concat(initial.warnings, "; "))
	end
end

reload_review = function(session, state)
	if not state.provider or not state.pr then
		return
	end
	cancel_requests(state)
	state.generation = state.generation + 1
	local generation = state.generation
	state.loading = true
	session.refresh_ui()
	view_notify(session, "loading", "Refreshing review...")
	local handle = require("atlas.pulls.diff.shared.review").load({
		provider = state.provider,
		pr = state.pr,
		current_user = state.current_user,
		review_context = state.review_context,
		initial_review = {
			comments = state.comments,
			tasks = state.tasks,
			warnings = {},
		},
	}, { force_refresh = true }, function(result)
		if not active(session, state) or state.generation ~= generation then
			return
		end
		local warnings = result.initial_review.warnings
		apply_prepared(session, state, result)
		if #warnings == 0 then
			view_notify(session, "success", "Review refreshed", 1200)
		end
	end)
	track(session, state, handle)
end

---@param session AtlasReviewSession
---@param buf integer
---@return boolean
function M.has_at_cursor(session, buf)
	local state = session.review
	return state ~= nil and active(session, state) and #threads_at_cursor(session, state, buf) > 0
end

---@param session AtlasReviewSession
---@param buf integer
---@return boolean opened
function M.open_at_cursor(session, buf)
	local state = session.review
	return state ~= nil and active(session, state) and open_thread(session, state, buf) or false
end

---@param session AtlasReviewSession
---@return boolean started
function M.reload(session)
	local state = session.review
	if not state or not active(session, state) then
		return false
	end
	if state.loading then
		view_notify(session, "info", "Review items are still loading", 1200)
		return false
	end
	if not state.provider or not state.pr then
		view_notify(session, "info", "No pull request review is available", 1200)
		return false
	end
	reload_review(session, state)
	return true
end

---@param session AtlasReviewSession
---@param context AtlasPreparedReviewContext
function M.attach(session, context)
	if session.review then
		return
	end
	---@type AtlasReviewState
	local state = {
		comments = {},
		tasks = {},
		expanded_threads = {},
		request_handles = {},
		provider = nil,
		pr = nil,
		current_user = nil,
		review_context = nil,
		loading = true,
		generation = 0,
	}
	session.review = state
	apply_prepared(session, state, context)
	register_keymaps(session, state)
end

---@param session AtlasReviewSession
function M.detach(session)
	local state = session.review
	if not state then
		return
	end
	session.review = nil
	cancel_requests(state)
	require("atlas.pulls.diff.shared.comments.popup").close(tostring(session.tabpage))
	renderer.clear_comments(session.left.buf)
	renderer.clear_comments(session.right.buf)
end

return M
