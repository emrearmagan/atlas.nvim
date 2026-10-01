local annotations = require("atlas.pulls.diffv2.ui.annotations")
local comment_threads = require("atlas.pulls.ui.components.comment_threads")
local icons = require("atlas.ui.shared.icons")
local keymap_resolver = require("atlas.core.keymaps")
local keymaps = require("atlas.pulls.diffv2.ui.review_panel.keymaps")
local note_renderer = require("atlas.pulls.notes.ui.renderer")
local presentation = require("atlas.pulls.ui.presentation")
local review_actions = require("atlas.pulls.actions.review")
local utils = require("atlas.ui.shared.utils")

local M = {}
local namespace = vim.api.nvim_create_namespace("atlas.diffv2.review_panel")
local review_states = {
	approved = { "Approved", icons.pulls_status("successful") },
	changes_requested = { "Changes requested", icons.pulls_status("failed") },
	pending = { "Pending", icons.pulls_status("inprogress") },
	commented = { "Commented", icons.general("comment") },
	dismissed = { "Dismissed", icons.pulls_status("stopped") },
	unapproved = { "Approval removed", icons.pulls_status("stopped") },
	reviewed = { "Reviewed", icons.pulls("review") },
}

---@class AtlasDiffV2ReviewPanelRow
---@field key string
---@field tree_key string|nil
---@field comment PullsComment|nil
---@field thread_root PullsComment|nil
---@field note AtlasNote|nil
---@field review_entry PullsReviewHistoryEntry|nil

---@class AtlasDiffV2ReviewPanel
---@field data AtlasDiffV2Result
---@field buf integer
---@field win integer|nil
---@field group integer
---@field cursor_row integer
---@field expanded table<string, boolean>
---@field line_map table<integer, AtlasDiffV2ReviewPanelRow>

---@param action AtlasKeymapActionId
---@return string|nil
local function key_label(action)
	local keys = keymap_resolver.resolve(action)
	return keys and #keys > 0 and table.concat(keys, " / ") or nil
end

---@param node AtlasCommentThreadNode
---@return boolean
local function has_pending(node)
	if node.comment.pending then
		return true
	end
	for _, child in ipairs(node.children) do
		if has_pending(child) then
			return true
		end
	end
	return false
end

---@param comment PullsComment
---@return string
local function comment_location(comment)
	local position = comment.file or comment.inline
	if not position then
		return ""
	end
	local path = vim.fs.basename(position.path)
	local inline = comment.inline
	local line = inline and (inline.to or inline.from)
	local first = inline and (inline.to and inline.start_to or inline.start_from)
	if first and line and first ~= line then
		return string.format("%s:%d-%d", path, first, line)
	end
	return line and string.format("%s:%d", path, line) or path
end

---@param result AtlasDiffV2Result
---@return table[]
local function sections(result)
	local pending, reviews, tasks, comments, notes = {}, {}, {}, {}, {}
	local data = result.review and result.review.data
	if data then
		for _, thread in ipairs(review_actions.group_comments(data.comments, data.tasks)) do
			local comment = thread.comment
			local position = comment.file or comment.inline
			local items = comment.is_task and tasks or (has_pending(thread) and pending or comments)
			items[#items + 1] = {
				key = comment_threads.comment_key(comment),
				thread = thread,
				path = position and position.path or "",
				line = comment.inline and (comment.inline.to or comment.inline.from) or 0,
				timestamp = comment.created_on,
			}
		end

		local by_author = {}
		local function reviewer(author, fallback)
			local key = author and (author.id ~= "" and author.id or author.username:lower()) or fallback
			if not by_author[key] then
				by_author[key] = { key = "reviewer:" .. key, author = author, history = {} }
				reviews[#reviews + 1] = by_author[key]
			end
			return by_author[key]
		end
		for _, author in ipairs(data.reviewers) do
			reviewer(author).decision = author.decision
		end
		for index, entry in ipairs(data.history) do
			local item = reviewer(entry.author, "unknown:" .. (entry.id or index))
			item.history[#item.history + 1] = entry
		end
	end
	if result.notes then
		for _, note in ipairs(result.notes.items) do
			notes[#notes + 1] = {
				key = note_renderer.note_key(result.notes.target, note),
				note = note,
				path = note.file_path,
				line = note.line,
				timestamp = note.updated_at or note.created_at,
			}
		end
	end
	for _, items in ipairs({ pending, tasks, comments, notes }) do
		table.sort(items, function(a, b)
			if a.path ~= b.path then
				return a.path < b.path
			end
			if a.line ~= b.line then
				return a.line < b.line
			end
			if a.timestamp ~= b.timestamp then
				return a.timestamp < b.timestamp
			end
			return a.key < b.key
		end)
	end
	return {
		{ id = "pending", title = "Pending", item_name = "comment", items = pending },
		{ id = "reviews", title = "Reviews", item_name = "reviewer", items = reviews },
		{ id = "tasks", title = "Tasks", item_name = "task", items = tasks },
		{ id = "comments", title = "Comments", item_name = "comment", items = comments },
		{ id = "notes", title = "Notes", item_name = "note", items = notes },
	}
end

local function render_review(item, width, expanded, history_expanded, head_revision, edit_key)
	local lines, spans, line_map = {}, {}, {}
	local history = item.history
	local decision = item.decision or history[#history].state
	local status = review_states[decision]
	local author = item.author and (item.author.nickname or item.author.name) or "Unknown"

	local function add_line(chunks, entry)
		local text = ""
		for _, chunk in ipairs(chunks) do
			local start_col = #text
			text = text .. chunk[1]
			if chunk[2] and #text > start_col then
				spans[#spans + 1] = {
					line = #lines,
					start_col = start_col,
					end_col = #text,
					hl_group = chunk[2],
				}
			end
		end
		lines[#lines + 1] = text
		line_map[#lines] = entry
	end

	local previous = ""
	for index = #history, 1, -1 do
		local entry = history[index]
		if entry.state == decision then
			if entry.commit_hash and entry.commit_hash ~= head_revision then
				previous = "  previous commit"
			end
			break
		end
	end

	local fold, fold_hl = " ", nil
	if #history > 0 then
		fold, fold_hl = icons.general(expanded and "fold_open" or "fold_closed")
	end
	local user, user_hl = icons.general("user")
	local label = status[2] .. " " .. status[1]
	local name_width = math.max(1, width - vim.fn.strdisplaywidth(fold .. " " .. user .. "   " .. label .. previous))
	add_line({
		{ fold, fold_hl },
		{ " " .. user .. " ", user_hl },
		{ utils.truncate(author, name_width), presentation.author_hl(author) },
		{ "  " .. label, status[3] },
		{ previous, "AtlasTextMuted" },
	}, { key = item.key, tree_key = #history > 0 and item.key or nil })

	if not expanded or #history == 0 then
		return lines, spans, line_map
	end

	local history_key = item.key .. ":history"
	local function add_review(index)
		local entry = history[index]
		local latest = index == #history
		local body = vim.trim((entry.body or ""):gsub("%s+", " "))
		local show_status = not latest or entry.state ~= item.decision or body == ""
		local entry_status = review_states[entry.state]
		local prefix = show_status and entry_status[2] or ""
		if prefix ~= "" and body ~= "" then
			prefix = prefix .. "  "
		end
		local details = utils.relative_time(entry.submitted_on)
		if show_status and entry.commit_hash and entry.commit_hash ~= head_revision then
			details = details .. "  previous commit"
		end

		local target = {
			key = "review:" .. (entry.id or item.key .. ":" .. index),
			tree_key = latest and item.key or history_key,
			review_entry = entry,
		}
		if not latest then
			local body_width = math.max(0, width - vim.fn.strdisplaywidth(prefix .. details) - 2)
			add_line({
				{ prefix, entry_status[3] },
				{ utils.truncate(body, body_width), "Normal" },
				{ "  " .. details, "AtlasTextMuted" },
			}, target)
			return
		end

		local indent = string.rep(" ", vim.fn.strdisplaywidth(prefix))
		for row, text in ipairs(utils.wrap_line(body, math.max(1, width - #indent))) do
			add_line({ { row == 1 and prefix or indent, entry_status[3] }, { text, "Normal" } }, target)
		end
		if vim.fn.strdisplaywidth(lines[#lines] .. "  " .. details) <= width then
			local start_col = #lines[#lines] + 2
			lines[#lines] = lines[#lines] .. "  " .. details
			spans[#spans + 1] = {
				line = #lines - 1,
				start_col = start_col,
				end_col = #lines[#lines],
				hl_group = "AtlasTextMuted",
			}
		else
			add_line({ { indent .. details, "AtlasTextMuted" } }, target)
		end
		if edit_key and entry.id and body ~= "" then
			add_line({ { edit_key .. " edit", "AtlasTextMuted" } }, target)
		end
	end

	add_review(#history)
	if #history > 1 then
		local icon, hl = icons.general(history_expanded and "fold_open" or "fold_closed")
		local count = #history - 1
		local history_label = string.format("%d earlier %s", count, count == 1 and "review" or "reviews")
		add_line({ { icon .. " ", hl }, { history_label, "AtlasTextMuted" } }, {
			key = history_key,
			tree_key = history_key,
		})
		if history_expanded then
			for index = #history - 1, 1, -1 do
				add_review(index)
			end
		end
	end

	return lines, spans, line_map
end

---@param state AtlasDiffV2ReviewPanel
function M.render(state)
	if not state.win then
		return
	end
	local view = vim.api.nvim_win_call(state.win, vim.fn.winsaveview)
	local selected = state.line_map[view.lnum]
	local width = vim.api.nvim_win_get_width(state.win)
	local comment_options = annotations.comment_options(state.data)
	local lines, spans, line_map = {}, {}, {}
	local action_keys = {
		reply = key_label("pulls.review.add_comment"),
		add_task = key_label("pulls.review.add_task"),
		edit = key_label("ui.comments.edit"),
		delete = key_label("ui.delete"),
		toggle_resolved = key_label("pulls.review.toggle_resolved"),
	}
	local previous = state.expanded
	state.expanded = {}
	local function expanded(key, default)
		local value = previous[key]
		if value == nil then
			value = default
		end
		state.expanded[key] = value
		return value
	end

	for _, section in ipairs(sections(state.data)) do
		if #section.items > 0 then
			local key = "section:" .. section.id
			local section_open = expanded(key, section.id ~= "notes")
			if #lines > 0 then
				lines[#lines + 1] = ""
			end
			local icon, hl = icons.general(section_open and "fold_open" or "fold_closed")
			local header = icon .. " " .. section.title
			local count = #section.items
			local name = count == 1 and section.item_name or section.item_name .. "s"
			lines[#lines + 1] = string.format("%s  %d %s", header, count, name)
			spans[#spans + 1] = { line = #lines - 1, start_col = 0, end_col = #icon, hl_group = hl }
			spans[#spans + 1] = {
				line = #lines - 1,
				start_col = #header + 2,
				end_col = #lines[#lines],
				hl_group = "AtlasTextMuted",
			}
			line_map[#lines] = { key = key, tree_key = key }
			for index, item in ipairs(section.items) do
				local item_open = false
				if not item.history or #item.history > 0 then
					item_open = expanded(item.key, section.id == "pending")
				end
				local history_open = false
				if item.history and #item.history > 1 then
					history_open = expanded(item.key .. ":history", false)
				end
				if section_open then
					local content, highlights, entries
					if item.thread then
						content, highlights, entries = comment_threads.render_compact(
							item.thread,
							width,
							item_open,
							comment_location(item.thread.comment),
							{
								action_keys = action_keys,
								format_text = comment_options.format_text,
								reaction_options = comment_options.reaction_options,
							}
						)
					elseif item.note then
						content, highlights, entries = note_renderer.render_list({
							{ target = state.data.notes.target, note = item.note, expanded = item_open },
						}, width, { action_keys = action_keys })
					else
						content, highlights, entries = render_review(
							item,
							width,
							item_open,
							history_open,
							state.data.head_revision,
							action_keys.edit
						)
					end
					local offset = #lines
					utils.append_block(lines, spans, { lines = content, highlights = highlights })
					for row, entry in pairs(entries) do
						entry.key = entry.key
							or (entry.comment and comment_threads.comment_key(entry.comment))
							or item.key
						entry.tree_key = entry.tree_key or (item.thread and item.key)
						line_map[offset + row] = entry
					end
					if item_open and index < #section.items then
						lines[#lines + 1] = ""
					end
				end
			end
		end
	end
	if #lines == 0 then
		lines = { "No review items." }
	end
	state.line_map = line_map
	vim.bo[state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.bo[state.buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(state.buf, namespace, span.line, span.start_col, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
	view.lnum = math.min(view.lnum, #lines)
	if selected then
		local selected_row, root_row
		for row = 1, #lines do
			if line_map[row] and line_map[row].key == selected.key then
				selected_row = row
				break
			end
			if line_map[row] and line_map[row].key == selected.tree_key then
				root_row = row
			end
		end
		view.lnum = selected_row or root_row or view.lnum
	end
	state.cursor_row = view.lnum
	vim.api.nvim_win_call(state.win, function()
		vim.fn.winrestview(view)
	end)
end

---@param result AtlasDiffV2Result
---@param callbacks { on_select: fun(entry: AtlasDiffV2ReviewPanelRow, focus: boolean), on_action: fun(id: AtlasReviewActionId, target: { comment?: PullsComment, note?: AtlasNote, review_entry?: PullsReviewHistoryEntry, pending?: boolean }) }
---@return AtlasDiffV2ReviewPanel
function M.create(result, callbacks)
	local buf = vim.api.nvim_create_buf(false, true)
	---@type AtlasDiffV2ReviewPanel
	local state = {
		data = result,
		buf = buf,
		group = vim.api.nvim_create_augroup("AtlasDiffV2ReviewPanel" .. buf, { clear = true }),
		cursor_row = 1,
		expanded = {},
		line_map = {},
	}
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].filetype = "atlas.review"
	vim.bo[buf].syntax = "OFF"
	vim.bo[buf].modifiable = false

	keymaps.setup(state, {
		on_select = callbacks.on_select,
		on_action = callbacks.on_action,
		render = function()
			M.render(state)
		end,
		close = function()
			M.close(state)
		end,
	})

	vim.api.nvim_create_autocmd("CursorMoved", {
		group = state.group,
		buffer = buf,
		callback = function()
			if state.win then
				state.cursor_row = vim.api.nvim_win_get_cursor(state.win)[1]
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = state.group,
		callback = function(event)
			if tonumber(event.match) == state.win then
				state.win = nil
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinResized", {
		group = state.group,
		callback = function()
			if state.win and vim.tbl_contains(vim.v.event.windows, state.win) then
				M.render(state)
			end
		end,
	})
	return state
end

---@param state AtlasDiffV2ReviewPanel
---@return integer
local function height(state)
	local configured = math.max(4, math.floor(state.data.options.review_panel.height))
	return math.min(configured, math.max(4, vim.o.lines - 8))
end

---@param state AtlasDiffV2ReviewPanel
function M.resize(state)
	if state.win then
		vim.api.nvim_win_set_height(state.win, height(state))
		M.render(state)
	end
end

---@param state AtlasDiffV2ReviewPanel
---@return integer
function M.open(state)
	if state.win then
		return state.win
	end
	state.win = vim.api.nvim_open_win(state.buf, false, {
		split = "below",
		win = -1,
		height = height(state),
	})
	vim.api.nvim_win_set_cursor(state.win, { state.cursor_row, 0 })
	local options = vim.wo[state.win][0]
	options.winfixheight = true
	options.number = false
	options.relativenumber = false
	options.signcolumn = "no"
	options.statuscolumn = ""
	options.winbar = " Atlas Review"
	options.winhighlight = ""
	options.foldcolumn = "0"
	options.fillchars = "eob: "
	options.wrap = false
	options.cursorline = true
	options.cursorcolumn = false
	options.foldenable = false
	options.diff = false
	options.scrollbind = false
	options.cursorbind = false
	options.colorcolumn = ""
	options.list = false
	options.spell = false
	M.render(state)
	return state.win
end

---@param state AtlasDiffV2ReviewPanel
function M.close(state)
	if state.win then
		state.cursor_row = vim.api.nvim_win_get_cursor(state.win)[1]
		vim.api.nvim_win_close(state.win, true)
	end
end

---@param state AtlasDiffV2ReviewPanel
function M.dispose(state)
	M.close(state)
	vim.api.nvim_del_augroup_by_id(state.group)
	if vim.api.nvim_buf_is_valid(state.buf) then
		vim.api.nvim_buf_delete(state.buf, { force = true })
	end
end

return M
