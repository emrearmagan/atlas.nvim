local box = require("atlas.ui.components.box")
local icons = require("atlas.ui.shared.icons")
local keymaps = require("atlas.core.keymaps")
local note_renderer = require("atlas.pulls.notes.ui.renderer")
local providers = require("atlas.providers")
local review_actions = require("atlas.pulls.actions.review")
local statusline = require("atlas.ui.statusline")
local thread_ui = require("atlas.pulls.ui.components.comment_threads")
local utils = require("atlas.ui.shared.utils")
local virtual_lines = require("atlas.ui.components.virtual_lines")

local M = {}
local namespace = vim.api.nvim_create_namespace("atlas.diff.annotations.popup")
local popup

---@class AtlasDiffAnnotation
---@field side "LEFT"|"RIGHT"
---@field line integer|nil
---@field thread AtlasCommentThreadNode|nil
---@field note AtlasNote|nil
---@field outdated boolean|nil

---@param result AtlasDiffResult
---@param expanded_threads table<string, boolean>|nil
---@return AtlasCommentThreadRenderOptions
function M.comment_options(result, expanded_threads)
	local options = {}
	if expanded_threads then
		options.expanded = function(comment)
			return thread_ui.is_thread_expanded(comment, expanded_threads)
		end
	end

	local pr = result.pr
	if not pr then
		return options
	end

	local provider = providers.load(pr.provider, "pulls")
	---@cast provider PullsProvider|nil
	local comments = provider and provider.capabilities.comments
	if not comments then
		return options
	end

	options.reaction_options = comments.reaction_options
	local review = result.review
	if review and review.data and comments.comment_formatter then
		options.format_text = comments.comment_formatter({
			pr = pr,
			data = review.data,
			review_context = review.context,
		})
	end

	return options
end

---@param result AtlasDiffResult
---@param file AtlasDiffFile
---@return AtlasDiffAnnotation[]
function M.for_file(result, file)
	local items = {}
	local review = result.review and result.review.data
	if review then
		for _, thread in ipairs(review_actions.group_comments(review.comments, review.tasks)) do
			local comment = thread.comment
			local target = comment.file or comment.inline
			if target and (target.path == file.path or target.path == file.old_path) then
				local side = file.status == "deleted" and "LEFT" or "RIGHT"
				local line
				if comment.inline then
					side = comment.inline.to and "RIGHT" or "LEFT"
					line = comment.inline.to or comment.inline.from
				end

				items[#items + 1] = { side = side, line = line, thread = thread }
			end
		end
	end

	if result.notes and not file.binary and file.status ~= "deleted" then
		for _, note in ipairs(result.notes.items) do
			if note.file_path == file.path or (file.status == "renamed" and note.file_path == file.old_path) then
				items[#items + 1] = { side = "RIGHT", line = note.line, note = note }
			end
		end
	end

	return items
end

---@param view AtlasDiffView
---@param all boolean|nil
---@return boolean toggled
function M.toggle_threads(view, all)
	if view.result.options.comment_display ~= "virtual_lines" then
		return false
	end

	local items
	if all and view.current_file then
		items = M.for_file(view.result, view.current_file)
	else
		local by_line = view.annotations[vim.api.nvim_get_current_buf()]
		items = by_line and by_line[vim.api.nvim_win_get_cursor(0)[1]] or {}
	end

	local threads = vim.iter(items)
		:map(function(item)
			return item.thread
		end)
		:totable()
	return thread_ui.toggle_all_threads(threads, view.expanded_threads)
end

---@param comment PullsComment
---@return string
local function comment_location(comment)
	if comment.file then
		return vim.fs.basename(comment.file.path)
	end

	local inline = comment.inline
	if not inline then
		return ""
	end

	local line = inline.to or inline.from
	if not line then
		return ""
	end

	local side = inline.to and "R" or "L"
	local first = inline.to and inline.start_to or inline.start_from
	if first and first ~= line then
		return string.format("%s%d-%s%d", side, first, side, line)
	end

	return side .. line
end

---@param note AtlasNote
---@return string
local function note_location(note)
	return "R" .. note.line
end

---@param items AtlasDiffAnnotation[]
---@param format_text (fun(text: string): string)|nil
---@return [string, string][]
function M.render_virtual_text(items, format_text)
	local chunks = {}
	for index, item in ipairs(items) do
		local body
		local markers = {}
		if item.note then
			body = item.note.body
			markers = note_renderer.status_marker(item.note, item.outdated)
		elseif item.thread then
			local comment = item.thread.comment
			body = format_text and format_text(comment.content_raw) or comment.content_raw
			markers = thread_ui.status_marker(comment)
			if comment.state == "DELETED" then
				body = "(deleted comment)"
			end
		end

		local text = utils.truncate(utils.strip_markup(body):gsub("%s+", " "), 48)
		local icon, highlight = icons.general(item.note and "pin" or "comment")
		if index > 1 then
			chunks[#chunks + 1] = { "   ", "AtlasTextMuted" }
		end
		chunks[#chunks + 1] = { icon .. " ", item.note and highlight or "AtlasLogInfo" }
		chunks[#chunks + 1] = { text, "AtlasTextMuted" }
		if #markers > 0 then
			chunks[#chunks + 1] = { " ", "AtlasTextMuted" }
			vim.list_extend(chunks, markers)
		end
	end

	return chunks
end

---@param items AtlasDiffAnnotation[]
---@param width integer
---@param options AtlasCommentThreadRenderOptions
---@return [string, string|string[]][][]
function M.render_virtual_lines(items, width, options)
	local comments, note_items, outdated = {}, {}, {}
	for _, item in ipairs(items) do
		if item.thread then
			comments[#comments + 1] = item.thread
		else
			note_items[#note_items + 1] = item.note
			outdated[item.note.id] = item.outdated
		end
	end

	local result = {}
	if #comments > 0 then
		local lines, spans = thread_ui.render(comments, math.max(1, width - 4), {
			expanded = function(comment)
				return options.expanded and options.expanded(comment) or false
			end,
			padding_x = 0,
			location = comment_location,
			format_text = options.format_text,
			reaction_options = options.reaction_options,
		})
		local rendered = box.render({ { lines = lines, spans = spans } }, { width = width, padding_x = 0 })
		vim.list_extend(result, virtual_lines.render(rendered.lines, rendered.highlights))
	end

	if #note_items > 0 then
		local lines, spans = note_renderer.render_cards(note_items, width, {
			expanded = false,
			outdated = outdated,
			location = note_location,
		})
		vim.list_extend(result, virtual_lines.render(lines, spans))
	end

	return result
end

---@param view AtlasDiffView
---@param direction 1|-1
---@param kind "comment"|"note"
---@param from_edge boolean|nil
---@param display_line fun(pane: integer, line: integer): integer
---@return boolean moved
function M.navigate(view, direction, kind, from_edge, display_line)
	local locations = {}
	local field = kind == "comment" and "thread" or "note"
	for index, pane in ipairs({ view.left, view.right }) do
		if pane.win then
			for line, items in pairs(view.annotations[pane.buf] or {}) do
				if vim.iter(items):any(function(item)
					return item[field] ~= nil
				end) then
					locations[#locations + 1] = {
						pane = index,
						win = pane.win,
						line = line,
						row = display_line(index, line),
					}
				end
			end
		end
	end
	if #locations == 0 then
		return false
	end

	table.sort(locations, function(a, b)
		return a.row == b.row and a.pane < b.pane or a.row < b.row
	end)
	local pane = vim.api.nvim_get_current_win() == view.left.win and 1 or 2
	local win = pane == 1 and view.left.win or view.right.win
	local cursor = display_line(pane, vim.api.nvim_win_get_cursor(win)[1])
	local first = direction == 1 and 1 or #locations
	local last = direction == 1 and #locations or 1

	for index = first, last, direction do
		local location = locations[index]
		local distance = location.row == cursor and location.pane - pane or location.row - cursor
		if from_edge or distance * direction > 0 then
			vim.api.nvim_set_current_win(location.win)
			vim.api.nvim_win_set_cursor(location.win, { location.line, 0 })
			vim.cmd("normal! zv")
			return true
		end
	end

	return false
end

---@param view AtlasDiffView
---@param target { comment?: PullsComment, note?: AtlasNote }
---@param focus boolean
function M.jump(view, target, focus)
	for _, pane in ipairs({ view.left, view.right }) do
		if pane.win then
			for line, items in pairs(view.annotations[pane.buf] or {}) do
				local found = vim.iter(items):any(function(item)
					return target.note and item.note == target.note
						or target.comment and item.thread and item.thread.comment == target.comment
				end)

				if found then
					vim.api.nvim_win_call(pane.win, function()
						vim.api.nvim_win_set_cursor(pane.win, { line, 0 })
						vim.cmd("normal! zv")
					end)

					if focus then
						vim.api.nvim_set_current_win(pane.win)
					end
					return
				end
			end
		end
	end
end

---@param owner integer|nil
function M.close(owner)
	if not popup or owner and popup.owner ~= owner then
		return
	end

	if vim.api.nvim_win_is_valid(popup.win) then
		local focused = vim.api.nvim_get_current_win() == popup.win
		vim.api.nvim_win_close(popup.win, true)
		if focused and vim.api.nvim_win_is_valid(popup.source_win) then
			vim.api.nvim_set_current_win(popup.source_win)
		end
	end

	popup = nil
end

---@param owner integer
---@param result AtlasDiffResult
---@param path string
---@param items AtlasDiffAnnotation[]
---@param on_action fun(action: AtlasReviewActionId, target: {comment?: PullsComment, note?: AtlasNote, pending?: boolean}, on_submit: fun())
function M.open(owner, result, path, items, on_action)
	M.close()
	local source_win = vim.api.nvim_get_current_win()

	local pr = result.pr
	local provider = pr and providers.load(pr.provider, "pulls")
	---@cast provider PullsProvider|nil
	local tasks = provider and provider.capabilities.tasks
	local can_add_task = tasks and tasks.add_task ~= nil
	local comment_options = M.comment_options(result)

	local keys = {
		close = keymaps.resolve("ui.close"),
		reply = keymaps.resolve("ui.comments.reply"),
		add_task = can_add_task and keymaps.resolve("pulls.review.add_task") or nil,
		edit = keymaps.resolve("ui.comments.edit"),
		delete = keymaps.resolve("ui.delete"),
		toggle_resolved = keymaps.resolve("pulls.review.toggle_resolved"),
	}
	local labels = {}
	for name, bindings in pairs(keys) do
		if #bindings > 0 then
			labels[name] = table.concat(bindings, " / ")
		end
	end

	local width = math.max(1, math.min(100, vim.o.columns - 4))
	local lines, highlights, line_map = {}, {}, {}
	for _, item in ipairs(items) do
		if #lines > 0 then
			lines[#lines + 1] = ""
		end

		local content, spans, entries
		if item.thread then
			content, spans, entries = thread_ui.render({ item.thread }, width, {
				padding_x = 2,
				action_keys = labels,
				location = comment_location,
				format_text = comment_options.format_text,
				reaction_options = comment_options.reaction_options,
			})
		else
			content, spans, entries = note_renderer.render_cards({ item.note }, width, {
				boxed = false,
				padding_x = 2,
				action_keys = labels,
				outdated = { [item.note.id] = item.outdated },
				location = note_location,
			})
		end

		for line, entry in pairs(entries) do
			line_map[#lines + line] = entry
		end
		utils.append_block(lines, highlights, { lines = content, highlights = spans })
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "atlas-ui.review-thread"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false

	for _, highlight in ipairs(highlights) do
		vim.api.nvim_buf_set_extmark(buf, namespace, highlight.line, highlight.start_col or 0, {
			end_col = highlight.end_col,
			hl_group = highlight.hl_group,
			line_hl_group = highlight.line_hl_group,
		})
	end

	local first = items[1]
	local same_line = true
	for _, item in ipairs(items) do
		if item.side ~= first.side or item.line ~= first.line then
			same_line = false
			break
		end
	end

	local title = path
	if same_line and first.line then
		title = string.format("%s:%d (%s)", path, first.line, first.side)
	end

	local height = math.max(1, math.min(#lines, vim.o.lines - 6))
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " ",
		title_pos = "center",
		zindex = 40,
	})
	popup = { owner = owner, win = win, source_win = source_win }

	vim.wo[win].cursorline = true
	vim.wo[win].wrap = false
	vim.wo[win].foldenable = false
	vim.wo[win].diff = false
	vim.wo[win].scrollbind = false
	vim.wo[win].cursorbind = false
	vim.wo[win].winhighlight = "Normal:NormalFloat,NormalNC:NormalFloat,FloatBorder:FloatBorder"
	statusline.inherit(win, source_win)

	local function close()
		if popup and popup.win == win then
			M.close(owner)
		end
	end

	---@param name AtlasReviewActionId
	local function action(name)
		return function()
			local entry = line_map[vim.api.nvim_win_get_cursor(win)[1]]
			if not entry then
				return
			end

			if entry.note then
				if name == "toggle_resolved" then
					on_action("toggle_note_resolved", { note = entry.note }, close)
				elseif name == "edit_comment" or name == "delete_comment" then
					local note_action = name == "edit_comment" and "edit_note" or "delete_note"
					on_action(note_action, { note = entry.note }, close)
				end
			elseif entry.comment then
				local target = entry.comment
				local selected_action = name
				if name == "toggle_resolved" then
					selected_action = target.is_task and "toggle_task" or "toggle_resolved"
					target = target.is_task and target or entry.thread_root
				end
				on_action(selected_action, { comment = target, pending = name == "add_comment" or nil }, close)
			end
		end
	end

	local map_opts = { buffer = buf, silent = true, nowait = true }
	local function map(bindings, callback)
		for _, key in ipairs(bindings or {}) do
			vim.keymap.set("n", key, callback, map_opts)
		end
	end

	map(keys.close, close)
	vim.keymap.set("n", "<Esc>", close, map_opts)
	map(keys.reply, action("add_comment"))
	map(keys.add_task, action("add_task"))
	map(keys.edit, action("edit_comment"))
	map(keys.delete, action("delete_comment"))
	map(keys.toggle_resolved, action("toggle_resolved"))
end

return M
