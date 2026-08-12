local M = {}

local actions = require("atlas.pulls.actions.review")
local code_preview = require("atlas.ui.components.code_preview")
local keymaps = require("atlas.core.keymaps")
local position = require("atlas.pulls.diff.position")
local review = require("atlas.pulls.diff.review")
local review_threads = require("atlas.ui.components.review_threads")
local ui = require("atlas.pulls.diff.ui.comments")

local ACTIONS = {
	add_comment = function(context, comment, on_done)
		return actions.add_comment(context, { parent = comment, pending = true }, on_done)
	end,
	edit = actions.edit_comment,
	delete = actions.delete_comment,
	toggle_task = actions.toggle_task,
	toggle_resolved = actions.toggle_resolved,
}

---@param session AtlasDiffSession
---@param level "loading"|"success"|"warn"|"error"|"info"
---@param message string
---@param duration integer|nil
local function notify(session, level, message, duration)
	if session.notify then
		session.notify(level, message, duration)
	end
end

---@param session AtlasDiffSession
---@return AtlasCommentRendererContext|nil
local function render_context(session)
	local current = session.current
	local review = session.review
	if not current or not review then
		return nil
	end
	local capability = review.provider.capabilities.comments
	return {
		threads = review_threads.group_comments(review.comments, review.tasks),
		expanded_threads = session.expanded_threads,
		old_path = current.document.old.path,
		new_path = current.document.new.path,
		reaction_options = capability and capability.reaction_options,
	}
end

---@param session AtlasDiffSession
---@param context AtlasCommentRendererContext
---@param path string
---@param side AtlasDiffSide
---@return table<integer, AtlasReviewThreadNode[]>, AtlasReviewThreadNode[]
local function threads_by_line(session, context, path, side)
	local document = session.current.document
	local lines = side == "LEFT" and document.old.lines or document.new.lines
	local result, file_threads = {}, {}
	for _, node in ipairs(context.threads) do
		local comment = node.comment
		local target = comment.file or comment.inline
		local comment_side, line = position.comment(document, comment)
		local matches = target and target.path == path
		if target and not matches and (path == context.old_path or path == context.new_path) then
			matches = target.path == context.old_path or target.path == context.new_path
		end
		if matches and comment_side == side and comment.file then
			file_threads[#file_threads + 1] = node
		elseif matches and comment_side == side and line and line >= 1 and #lines > 0 then
			line = math.min(line, math.max(1, #lines))
			result[line] = result[line] or {}
			result[line][#result[line] + 1] = node
		end
	end
	return result, file_threads
end

---@param session AtlasDiffSession
---@param side AtlasDiffSide
---@param line integer
---@return integer, boolean
local function opposite_line(session, side, line)
	local current = session.current
	local target = side == "LEFT" and current.right.buf or current.left.buf
	return position.opposite_line(current.document, side, line, vim.api.nvim_buf_line_count(target))
end

---@param session AtlasDiffSession
---@param context AtlasCommentRendererContext
---@param path string
---@param side AtlasDiffSide
---@return table<integer, AtlasReviewThreadNode[]>, table<integer, boolean>, AtlasReviewThreadNode[]
local function visible_threads(session, context, path, side)
	local result, file_threads = threads_by_line(session, context, path, side)
	local above = {}
	if session.current.layout ~= "inline" or side ~= "RIGHT" then
		return result, above, file_threads
	end
	local old_by_line, old_file_threads = threads_by_line(session, context, context.old_path, "LEFT")
	for old_line, old_threads in pairs(old_by_line) do
		local line, is_above = opposite_line(session, "LEFT", old_line)
		result[line] = result[line] or {}
		vim.list_extend(result[line], old_threads)
		above[line] = is_above or nil
	end
	vim.list_extend(file_threads, old_file_threads)
	return result, above, file_threads
end

---@param session AtlasDiffSession
---@return table<string, { comments: boolean, notes: boolean }>
function M.annotated_paths(session)
	local paths = {}
	local review = session.review
	for _, comment in ipairs(review and review.comments or {}) do
		local target = comment.file or comment.inline
		if target then
			paths[target.path] = paths[target.path] or { comments = false, notes = false }
			paths[target.path].comments = true
		end
	end
	for _, note in ipairs(session.notes) do
		paths[note.file_path] = paths[note.file_path] or { comments = false, notes = false }
		paths[note.file_path].notes = true
	end
	return paths
end

---@param session AtlasDiffSession
---@param context AtlasCommentRendererContext
---@param inline_deleted_lines boolean
---@return table
local function placed_threads(session, context, inline_deleted_lines)
	local current = session.current
	local placed = {
		right = {},
		right_above = {},
		right_file = {},
		left = {},
		left_above = {},
		left_file = {},
		deleted = {},
	}
	if inline_deleted_lines and current.layout == "inline" then
		placed.right, placed.right_file = threads_by_line(session, context, context.new_path, "RIGHT")
		local old_by_line, old_file_threads = threads_by_line(session, context, context.old_path, "LEFT")
		for old_line, list in pairs(old_by_line) do
			if position.is_changed(current.document, "LEFT", old_line) then
				placed.deleted[old_line] = list
			else
				local line, above = opposite_line(session, "LEFT", old_line)
				placed.right[line] = placed.right[line] or {}
				vim.list_extend(placed.right[line], list)
				placed.right_above[line] = above or nil
			end
		end
		vim.list_extend(placed.right_file, old_file_threads)
	else
		placed.right, placed.right_above, placed.right_file =
			visible_threads(session, context, context.new_path, "RIGHT")
	end
	if current.layout == "side-by-side" then
		placed.left, placed.left_above, placed.left_file = visible_threads(session, context, context.old_path, "LEFT")
	end
	return placed
end

---@param target AtlasDiffHint[]
---@param buf integer
---@param line integer
---@param list AtlasReviewThreadNode[]
local function add_line_hints(target, buf, line, list)
	for _, node in ipairs(list) do
		target[#target + 1] = {
			buf = buf,
			line = line,
			kind = "comment",
			text = node.comment.content_display or node.comment.content_raw,
		}
	end
end

---@param target AtlasDiffHint[]
---@param buf integer
---@param by_line table<integer, AtlasReviewThreadNode[]>
local function add_hints(target, buf, by_line)
	for line, list in pairs(by_line) do
		add_line_hints(target, buf, line, list)
	end
end

---@param session AtlasDiffSession
---@param inline_deleted_lines boolean
---@return AtlasDiffHint[], table<integer, AtlasDiffHint[]>
function M.hints(session, inline_deleted_lines)
	local current = session.current
	local context = render_context(session)
	if not current or not context then
		return {}, {}
	end
	local placed = placed_threads(session, context, inline_deleted_lines)
	local items = {}
	add_hints(items, current.right.buf, placed.right)
	add_hints(items, current.left.buf, placed.left)
	add_line_hints(items, current.right.buf, 1, placed.right_file)
	add_line_hints(items, current.left.buf, 1, placed.left_file)
	local deleted_hints = {}
	for line, list in pairs(placed.deleted) do
		deleted_hints[line] = {}
		add_line_hints(deleted_hints[line], current.right.buf, line, list)
	end
	return items, deleted_hints
end

---@param session AtlasDiffSession
---@param inline_deleted_lines boolean
---@return table<integer, [string, string][][]>
function M.render(session, inline_deleted_lines)
	local current = session.current
	local context = render_context(session)
	if not current or not context then
		return {}
	end
	local placed = placed_threads(session, context, inline_deleted_lines)
	local deleted = {}
	for line, list in pairs(placed.deleted) do
		deleted[line] = ui.thread_lines(context, current.right.buf, list)
	end
	local right = ui.render_comments(context, current.right.buf, placed.right, placed.right_above)
	local right_file_size = ui.render_file_comments(context, current.right.buf, placed.right_file)
	if current.layout ~= "side-by-side" then
		if vim.api.nvim_buf_is_valid(current.left.buf) then
			vim.api.nvim_buf_clear_namespace(
				current.left.buf,
				vim.api.nvim_create_namespace("atlas_diff_comments"),
				0,
				-1
			)
		end
		return deleted
	end
	local left = ui.render_comments(context, current.left.buf, placed.left, placed.left_above)
	local left_file_size = ui.render_file_comments(context, current.left.buf, placed.left_file)
	for line, count in pairs(left) do
		local target, above = opposite_line(session, "LEFT", line)
		ui.pad(current.right.buf, target, count, placed.left_above[line] or above)
	end
	for line, count in pairs(right) do
		local target, above = opposite_line(session, "RIGHT", line)
		ui.pad(current.left.buf, target, count, placed.right_above[line] or above)
	end
	if left_file_size > 0 then
		ui.pad(current.right.buf, 1, left_file_size, true)
	end
	if right_file_size > 0 then
		ui.pad(current.left.buf, 1, right_file_size, true)
	end
	return deleted
end

---@param session AtlasDiffSession
---@param buf integer
---@return string|nil, AtlasDiffSide|nil
local function buffer_context(session, buf)
	local current = session.current
	if not current then
		return nil, nil
	end
	if buf == current.left.buf then
		return current.document.old.path, "LEFT"
	end
	if buf == current.right.buf then
		return current.document.new.path, "RIGHT"
	end
	return nil, nil
end

---@param session AtlasDiffSession
---@param buf integer
---@return PullsInlineCommentPosition|nil, string|nil
local function inline_position(session, buf)
	local current = session.current
	local _, side = buffer_context(session, buf)
	if not current or not side then
		return nil, "This buffer is not part of the diff"
	end
	local inline, err = position.from_line(current.document, side, vim.api.nvim_win_get_cursor(0)[1])
	if inline then
		inline.commit_hash = session.source.head_revision
	end
	return inline, err
end

---@param session AtlasDiffSession
---@param buf integer
---@return AtlasMarkdownEditorPreview|nil
local function inline_preview(session, buf)
	local current = session.current
	local _, side = buffer_context(session, buf)
	if not current or not side or current.document.binary then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local source = side == "LEFT" and current.document.old or current.document.new
	local first = math.max(1, line - 2)
	local lines = {}
	for index = first, math.min(#source.lines, line + 2) do
		lines[#lines + 1] = source.lines[index]
	end
	return code_preview.render({ file_path = source.path, lines = lines, start_line = first, anchor_line = line })
end

---@param session AtlasDiffSession
---@param action AtlasReviewThreadAction
---@param comment PullsComment
---@param on_done fun()|nil
---@return boolean
function M.run_action(session, action, comment, on_done)
	local context = review.action_context(session, comment)
	local handler = ACTIONS[action]
	if not context or not handler then
		return false
	end
	return handler(context, comment, function(result, err)
		if result and not err then
			review.apply_action_data(session, context.data)
			session:render()
			if on_done then
				on_done()
			end
		end
	end)
end

---@param session AtlasDiffSession
---@param buf integer
---@return AtlasReviewThreadNode[]
local function at_cursor(session, buf)
	local path, side = buffer_context(session, buf)
	local context = render_context(session)
	if not path or not side or not context then
		return {}
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local by_line, _, file_threads = visible_threads(session, context, path, side)
	local nodes = vim.list_extend({}, by_line[line] or {})
	if line == 1 then
		vim.list_extend(nodes, file_threads)
	end
	return nodes
end

---@param session AtlasDiffSession
---@param buf integer
---@return boolean
function M.has_at_cursor(session, buf)
	return #at_cursor(session, buf) > 0
end

---@param nodes AtlasReviewThreadNode[]
---@return string
local function popup_title(nodes)
	local path, side, line, file_comment
	for _, node in ipairs(nodes) do
		local comment = node.comment
		local target = comment.file or comment.inline
		if target then
			local node_side, node_line = "RIGHT", 1
			if comment.inline then
				node_side, node_line = position.location(comment.inline)
			end
			if path and (path ~= target.path or side ~= node_side or line ~= node_line) then
				return " Review threads "
			end
			path, side, line, file_comment = target.path, node_side, node_line, comment.file ~= nil
		end
	end
	if file_comment and path then
		return string.format(" %s ", path)
	end
	return path and side and line and string.format(" %s:%d (%s) ", path, line, side) or " Review thread "
end

---@param session AtlasDiffSession
---@param buf integer
---@return boolean
function M.open_at_cursor(session, buf)
	local nodes = at_cursor(session, buf)
	if #nodes == 0 then
		return false
	end
	local owner = session.id
	local function open(current_nodes)
		local review = session.review
		local capability = review and review.provider.capabilities.comments
		ui.open_popup({
			nodes = current_nodes,
			owner = owner,
			title = popup_title(current_nodes),
			toggle_resolved_keys = keymaps.resolve("pulls.review.diff.toggle_resolved"),
			reaction_options = capability and capability.reaction_options,
			on_action = function(action, comment, close)
				M.run_action(session, action, comment, function()
					close()
				end)
			end,
		})
	end
	open(nodes)
	return true
end

---@param session AtlasDiffSession
---@param buf integer
---@return boolean
function M.toggle_at_cursor(session, buf)
	local nodes = at_cursor(session, buf)
	if not review_threads.toggle_all_threads(nodes, session.expanded_threads) then
		return false
	end
	session:render()
	return true
end

---@param session AtlasDiffSession
---@return boolean
function M.toggle_all(session)
	local context = render_context(session)
	if not context or not review_threads.toggle_all_threads(context.threads, session.expanded_threads) then
		return false
	end
	session:render()
	return true
end

---@param session AtlasDiffSession
---@param buf integer
---@param direction 1|-1
function M.jump(session, buf, direction)
	local _, current_side = buffer_context(session, buf)
	local context = render_context(session)
	if not current_side or not context then
		return
	end
	local locations = {}
	local sides = session.current.layout == "inline" and { "RIGHT" } or { "LEFT", "RIGHT" }
	for _, side in ipairs(sides) do
		local path = side == "LEFT" and context.old_path or context.new_path
		local by_line, _, file_threads = visible_threads(session, context, path, side)
		for line in pairs(by_line) do
			locations[#locations + 1] = {
				side = side,
				line = line,
				display = side == current_side and line or opposite_line(session, side, line),
			}
		end
		if #file_threads > 0 and by_line[1] == nil then
			locations[#locations + 1] = { side = side, line = 1, display = 1 }
		end
	end
	if #locations == 0 then
		return
	end
	table.sort(locations, function(a, b)
		return a.display == b.display and a.side < b.side or a.display < b.display
	end)
	local cursor = vim.api.nvim_win_get_cursor(0)[1]
	local target = direction > 0 and locations[1] or locations[#locations]
	if direction > 0 then
		for _, location in ipairs(locations) do
			if location.display > cursor or (location.display == cursor and location.side > current_side) then
				target = location
				break
			end
		end
	else
		for index = #locations, 1, -1 do
			local location = locations[index]
			if location.display < cursor or (location.display == cursor and location.side < current_side) then
				target = location
				break
			end
		end
	end
	local win = target.side == "LEFT" and session.current.left.win or session.current.right.win
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_set_current_win(win)
		vim.api.nvim_win_set_cursor(win, { target.line, 0 })
		local folded = vim.fn.foldclosed(target.line) ~= -1
		vim.cmd.normal({ "zvzz", bang = true })
		if folded and session.current.layout == "side-by-side" then
			local other = target.side == "LEFT" and session.current.right.win or session.current.left.win
			if other and vim.api.nvim_win_is_valid(other) then
				local line = opposite_line(session, target.side, target.line)
				vim.api.nvim_win_call(other, function()
					local previous = vim.api.nvim_win_get_cursor(other)
					vim.api.nvim_win_set_cursor(other, { line, 0 })
					vim.cmd.normal({ "zv", bang = true })
					vim.api.nvim_win_set_cursor(other, previous)
				end)
			end
		end
	end
end

---@param session AtlasDiffSession
---@param buf integer
---@param pending boolean
function M.add_at_cursor(session, buf, pending)
	local context = review.action_context(session)
	if not context then
		return
	end
	local inline, err = inline_position(session, buf)
	if not inline then
		notify(session, "info", err or "Cannot comment on this line")
		return
	end
	actions.add_comment(context, {
		inline = inline,
		pending = pending,
		preview = inline_preview(session, buf),
	}, function(result, action_err)
		if result and not action_err then
			review.apply_action_data(session, context.data)
			session:render()
		end
	end)
end

---@param session AtlasDiffSession
---@param file PullsFileCommentPosition
---@param pending boolean
function M.add_to_file(session, file, pending)
	local context = review.action_context(session)
	if not context then
		return
	end
	file.commit_hash = session.source.head_revision
	actions.add_comment(context, { file = file, pending = pending }, function(result, action_err)
		if result and not action_err then
			review.apply_action_data(session, context.data)
			session:render()
		end
	end)
end

---@param session AtlasDiffSession
---@param buf integer
function M.delete_at_cursor(session, buf)
	local nodes = at_cursor(session, buf)
	if #nodes == 1 then
		M.run_action(session, "delete", nodes[1].comment)
	elseif #nodes > 1 then
		M.open_at_cursor(session, buf)
	end
end

---@param session AtlasDiffSession
---@param buf integer
function M.toggle_resolved_at_cursor(session, buf)
	local nodes = at_cursor(session, buf)
	if #nodes == 1 then
		local comment = nodes[1].comment
		M.run_action(session, comment.is_task and "toggle_task" or "toggle_resolved", comment)
	elseif #nodes > 1 then
		M.open_at_cursor(session, buf)
	end
end

---@param session AtlasDiffSession
---@param buf integer
function M.open_in_browser(session, buf)
	for _, node in ipairs(at_cursor(session, buf)) do
		local url = tostring(node.comment.html_url or node.comment.url or "")
		if url ~= "" then
			vim.ui.open(url)
			return
		end
	end
	local review = session.review
	if review and review.pr.link and review.pr.link.html then
		vim.ui.open(review.pr.link.html)
	end
end

return M
