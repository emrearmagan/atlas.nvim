local M = {}

local help = require("atlas.ui.popups.help")
local icons = require("atlas.ui.shared.icons")
local note_renderer = require("atlas.pulls.notes.ui.renderer")
local resolver = require("atlas.core.keymaps")
local review_threads = require("atlas.ui.components.review_threads")
local utils = require("atlas.ui.shared.utils")
local namespace = vim.api.nvim_create_namespace("atlas.review_panel")

---@param comment PullsComment
---@return string
local function comment_location(comment)
	local inline = comment.inline
	if not inline then
		return ""
	end
	local path = inline.path:match("([^/\\]+)$") or inline.path
	local line = inline.to or inline.from
	local start_line = inline.to and inline.start_to or inline.start_from
	if line and start_line and line ~= start_line then
		return string.format("%s:%d-%d", path, start_line, line)
	end
	return line and string.format("%s:%d", path, line) or path
end

---@class AtlasReviewPanelSelection
---@field kind "comment"|"note"
---@field comment PullsComment|nil
---@field note AtlasNote|nil

---@class AtlasReviewPanelCallbacks
---@field on_select fun(item: AtlasReviewPanelSelection, focus_diff: boolean)
---@field on_refresh fun()
---@field on_close fun()

---@class AtlasReviewPanelData
---@field comments PullsComment[]
---@field notes AtlasNote[]
---@field note_target AtlasNoteTarget|nil

---@class AtlasReviewPanel
---@field buf integer
---@field win integer|nil
---@field line_map table<integer, table>
---@field data AtlasReviewPanelData
---@field callbacks AtlasReviewPanelCallbacks
---@field expanded_items table<string, boolean>

---@param buf integer
---@param win integer|nil
---@param callbacks AtlasReviewPanelCallbacks
---@return AtlasReviewPanel
function M.new(buf, win, callbacks)
	return {
		buf = buf,
		win = win,
		line_map = {},
		data = {
			comments = {},
			notes = {},
			note_target = nil,
		},
		callbacks = callbacks,
		expanded_items = {},
	}
end

---@param panel AtlasReviewPanel|nil
---@return boolean
local function active(panel)
	return panel ~= nil
		and panel.win ~= nil
		and vim.api.nvim_buf_is_valid(panel.buf)
		and vim.api.nvim_win_is_valid(panel.win)
end

---@param panel AtlasReviewPanel|nil
function M.configure(panel)
	if not active(panel) then
		return
	end
	vim.bo[panel.buf].filetype = "atlas-review"
	vim.wo[panel.win].cursorline = true
	vim.wo[panel.win].list = false
	vim.wo[panel.win].number = false
	vim.wo[panel.win].relativenumber = false
	vim.wo[panel.win].signcolumn = "no"
	vim.wo[panel.win].statuscolumn = ""
	vim.wo[panel.win].spell = false
	vim.wo[panel.win].wrap = false
	vim.wo[panel.win].foldenable = false
	vim.wo[panel.win].winfixheight = true
end

---@param panel AtlasReviewPanel
---@return table|nil
local function selected_entry(panel)
	if not active(panel) then
		return nil
	end
	return panel.line_map[vim.api.nvim_win_get_cursor(panel.win)[1]]
end

---@param entry table|nil
---@return string|nil
local function tree_key(entry)
	if not entry then
		return nil
	end
	local root = entry.thread_root or entry.comment
	return entry.tree_key or (root and review_threads.comment_key(root)) or nil
end

---@param data AtlasReviewPanelData
---@return table[], table[]
local function panel_items(data)
	local comments, notes = {}, {}
	for _, thread in ipairs(review_threads.group_comments(data.comments)) do
		local inline = thread.comment.inline
		table.insert(comments, {
			kind = "comment",
			thread = thread,
			key = review_threads.comment_key(thread.comment),
			path = inline and inline.path or "",
			line = inline and (inline.to or inline.from) or 0,
			timestamp = tostring(thread.comment.created_on or ""),
		})
	end
	if data.note_target then
		for _, note in ipairs(data.notes) do
			table.insert(notes, {
				kind = "note",
				note = note,
				key = note_renderer.note_key(data.note_target, note),
				path = note.file_path,
				line = note.line,
				timestamp = tostring(note.updated_at or note.created_at or ""),
			})
		end
	end
	local function sort_items(left, right)
		if left.path ~= right.path then
			return left.path < right.path
		end
		if left.line ~= right.line then
			return left.line < right.line
		end
		if left.timestamp ~= right.timestamp then
			return left.timestamp < right.timestamp
		end
		return left.key < right.key
	end
	table.sort(comments, sort_items)
	table.sort(notes, sort_items)
	return comments, notes
end

---@param panel AtlasReviewPanel|nil
---@param data AtlasReviewPanelData|nil
function M.render(panel, data)
	if not panel then
		return
	end
	if data then
		panel.data = data
	end
	if not active(panel) then
		return
	end

	local selected = tree_key(selected_entry(panel))
	local cursor = vim.api.nvim_win_get_cursor(panel.win)
	local width = math.max(6, vim.api.nvim_win_get_width(panel.win))
	local lines, spans, line_map = {}, {}, {}
	local comments, notes = panel_items(panel.data)
	local comment_icon = icons.general("comment")
	local note_icon, note_icon_hl = icons.general("pin")
	local sections = {
		{ title = "Comments", icon = comment_icon, icon_hl = "AtlasLogInfo", items = comments },
		{ title = "Notes", icon = note_icon, icon_hl = note_icon_hl, items = notes },
	}
	for _, section in ipairs(sections) do
		if #section.items > 0 then
			if #lines > 0 then
				table.insert(lines, "")
			end
			local title = string.format("%s %s", section.icon, section.title)
			local header = string.format("%s (%d)", title, #section.items)
			table.insert(lines, header)
			table.insert(spans, {
				line = #lines - 1,
				start_col = 0,
				end_col = #section.icon,
				hl_group = section.icon_hl,
			})
			table.insert(spans, {
				line = #lines - 1,
				start_col = #title + 1,
				end_col = #header,
				hl_group = "AtlasTextMuted",
			})
			for index, item in ipairs(section.items) do
				local expanded = panel.expanded_items[item.key] == true
				local block_lines, block_spans, block_map
				if item.kind == "comment" then
					block_lines, block_spans, block_map = review_threads.render_compact(
						item.thread,
						width,
						expanded,
						comment_location(item.thread.comment)
					)
				else
					block_lines, block_spans, block_map = note_renderer.render_list({
						{
							target = panel.data.note_target,
							note = item.note,
							expanded = expanded,
						},
					}, width)
				end
				local offset = #lines
				utils.append_block(lines, spans, { lines = block_lines, highlights = block_spans })
				for line, entry in pairs(block_map) do
					line_map[offset + line] = entry
				end
				if expanded and index < #section.items then
					table.insert(lines, "")
				end
			end
		end
	end
	if #lines == 0 then
		lines = { "No comments or local notes." }
	end

	vim.bo[panel.buf].modifiable = true
	vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
	vim.bo[panel.buf].modifiable = false
	panel.line_map = line_map
	vim.api.nvim_buf_clear_namespace(panel.buf, namespace, 0, -1)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(panel.buf, namespace, span.line, span.start_col, {
			end_row = span.line,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
	if selected then
		for line = 1, #lines do
			if tree_key(line_map[line]) == selected then
				vim.api.nvim_win_set_cursor(panel.win, { line, 0 })
				return
			end
		end
	end
	vim.api.nvim_win_set_cursor(panel.win, { math.min(cursor[1], #lines), 0 })
end

---@param entries table[]
---@param action AtlasKeymapActionId
---@param desc string
---@param index integer
---@param callback fun()
local function add_mapping(entries, action, desc, index, callback)
	local keys = resolver.resolve(action)
	if keys then
		table.insert(entries, {
			key = #keys == 1 and keys[1] or keys,
			desc = desc,
			index = index,
			callback = callback,
			opts = { nowait = true, silent = true },
		})
	end
end

---@param panel AtlasReviewPanel|nil
function M.register_keymaps(panel)
	if not panel then
		return
	end
	local function show_selected(focus_diff)
		local entry = selected_entry(panel)
		if entry and entry.note then
			panel.callbacks.on_select({ kind = "note", note = entry.note }, focus_diff)
		elseif entry and (entry.thread_root or entry.comment) then
			panel.callbacks.on_select({ kind = "comment", comment = entry.thread_root or entry.comment }, focus_diff)
		end
	end
	local entries = {}
	add_mapping(entries, "pulls.review.open_file", "Show item in diff", 1, function()
		show_selected(false)
	end)
	add_mapping(entries, "pulls.open_diff", "Open item in diff", 2, function()
		show_selected(true)
	end)
	add_mapping(entries, "ui.toggle_fold", "Expand / collapse", 3, function()
		local key = tree_key(selected_entry(panel))
		if key then
			panel.expanded_items[key] = not panel.expanded_items[key]
			M.render(panel)
		end
	end)
	add_mapping(entries, "ui.toggle_all_folds", "Expand / collapse all", 4, function()
		local comments, notes = panel_items(panel.data)
		local items = vim.list_extend(comments, notes)
		local expand = false
		for _, item in ipairs(items) do
			if panel.expanded_items[item.key] ~= true then
				expand = true
				break
			end
		end
		for _, item in ipairs(items) do
			panel.expanded_items[item.key] = expand
		end
		M.render(panel)
	end)
	add_mapping(entries, "ui.refresh", "Refresh review", 5, panel.callbacks.on_refresh)
	add_mapping(entries, "ui.close", "Close panel", 6, panel.callbacks.on_close)
	add_mapping(entries, "ui.help", "Toggle help", 0, function()
		help.toggle({ buffer = panel.buf })
	end)
	help.register("Review", entries, { index = 110, buffer = panel.buf })
end

return M
