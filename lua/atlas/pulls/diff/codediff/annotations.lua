local highlights = require("codediff.ui.highlights")
local ui = require("atlas.pulls.diff.ui.annotations")
local notes = require("atlas.pulls.notes")
local has_scroll, scroll = pcall(require, "codediff.ui.scroll")

local M = {}
local namespace = vim.api.nvim_create_namespace("atlas.diff.codediff.annotations")

local function native_rows(buf)
	local marks = vim.api.nvim_buf_get_extmarks(buf, highlights.ns_filler, 0, -1, { details = true })
	-- Moved-code labels take up a row too, but live with CodeDiff's highlights.
	vim.list_extend(marks, vim.api.nvim_buf_get_extmarks(buf, highlights.ns_highlight, 0, -1, { details = true }))

	local rows = {}
	for _, mark in ipairs(marks) do
		local details = mark[4]
		---@cast details vim.api.keyset.extmark_details
		if details.virt_lines then
			rows[#rows + 1] = {
				line = mark[2] + (details.virt_lines_above and 1 or 2),
				count = #details.virt_lines,
			}
		end
	end
	table.sort(rows, function(a, b)
		return a.line < b.line
	end)
	return rows
end

local function display_line(line, rows)
	local row = line
	for _, filler in ipairs(rows) do
		if filler.line > line then
			break
		end
		row = row + filler.count
	end
	return row
end

-- Use CodeDiff's actual fillers, including its word-level alignment.
local function aligned_line(line, source, target)
	local row = display_line(line, source)
	local offset = 0
	for _, filler in ipairs(target) do
		if row < filler.line + offset then
			break
		end
		if row < filler.line + offset + filler.count then
			-- A filler block has no real line to attach to.
			return filler.line - 1
		end
		offset = offset + filler.count
	end
	return row - offset
end

local function modified_line(line, changes)
	local offset = 0
	for _, change in ipairs(changes) do
		local original, modified = change.original, change.modified
		if line < original.start_line then
			break
		end
		if line < original.end_line then
			return modified.start_line, true
		end
		offset = offset + (modified.end_line - modified.start_line) - (original.end_line - original.start_line)
	end
	return line + offset, false
end

---@param view AtlasDiffCodeDiffView
function M.clear(view)
	for buf in pairs(view.annotations) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
		end
	end
	view.annotations = {}
end

---@param view AtlasDiffCodeDiffView
---@param file AtlasDiffFile
---@param session { original_bufnr: integer, modified_bufnr: integer, stored_diff_result: table }
function M.render(view, file, session)
	M.clear(view)

	local changes = session.stored_diff_result.changes
	local panes = { view.right }
	if view.left.win then
		table.insert(panes, 1, view.left)
	end

	local expanded = view.result.options.comment_display == "virtual_lines"
	local placed, fillers = {}, {}
	for _, pane in ipairs(panes) do
		view.annotations[pane.buf] = {}
		placed[pane.buf] = {}
		if expanded and view.left.win then
			fillers[pane.buf] = native_rows(pane.buf)
		end
	end

	local counts = {
		LEFT = file.status == "added" and 0 or vim.api.nvim_buf_line_count(session.original_bufnr),
		RIGHT = file.status == "deleted" and 0 or vim.api.nvim_buf_line_count(session.modified_bufnr),
	}
	local options = ui.comment_options(view.result, view.expanded_threads)

	for _, item in ipairs(ui.for_file(view.result, file)) do
		if item.thread and (file.binary or (item.line and (item.line < 1 or item.line > counts[item.side]))) then
			item.line = nil
		elseif item.note then
			local text = vim.api.nvim_buf_get_lines(view.right.buf, item.note.line - 1, item.note.line, false)[1]
			item.outdated = notes.is_outdated(item.note, text)
		end

		local pane = item.side == "LEFT" and view.left.win and view.left or view.right
		local line, deleted = item.line or 1, false
		if item.side == "LEFT" and not view.left.win and file.status ~= "deleted" and item.line then
			line, deleted = modified_line(item.line, changes)
		end
		line = math.max(1, math.min(line, vim.api.nvim_buf_line_count(pane.buf)))

		local lookup = view.annotations[pane.buf]
		lookup[line] = lookup[line] or {}
		table.insert(lookup[line], item)

		local boundary = line
		if expanded and not item.line then
			boundary = 0
		elseif expanded and deleted then
			-- CodeDiff owns the deleted block; put its cards beside the adjacent real line.
			boundary = line - 1
		end
		placed[pane.buf][boundary] = placed[pane.buf][boundary] or {}
		table.insert(placed[pane.buf][boundary], item)
	end

	local function put_lines(pane, line, rows, padding)
		line = math.min(line, vim.api.nvim_buf_line_count(pane.buf))
		vim.api.nvim_buf_set_extmark(pane.buf, namespace, math.max(0, line - 1), 0, {
			virt_lines = rows,
			virt_lines_above = line < 1,
			virt_lines_leftcol = true,
			priority = padding and 1090 or 1100,
		})
	end

	for _, pane in ipairs(panes) do
		for line in pairs(view.annotations[pane.buf]) do
			vim.api.nvim_buf_set_extmark(pane.buf, namespace, line - 1, 0, {
				sign_text = "┃",
				sign_hl_group = "AtlasLogInfo",
				number_hl_group = "CursorLineNr",
				priority = 1100,
			})
		end

		for line, items in pairs(placed[pane.buf]) do
			if expanded then
				local rows = vim.api.nvim_win_call(pane.win, function()
					return ui.render_virtual_lines(items, vim.api.nvim_win_get_width(pane.win), options)
				end)
				put_lines(pane, line, rows, false)

				if view.left.win then
					local other = pane == view.left and view.right or view.left
					local target = line == 0 and 0 or aligned_line(line, fillers[pane.buf], fillers[other.buf])
					local padding = {}
					for _ = 1, #rows do
						padding[#padding + 1] = { { "", "Normal" } }
					end
					put_lines(other, target, padding, true)
				end
			else
				vim.api.nvim_buf_set_extmark(pane.buf, namespace, line - 1, 0, {
					virt_text = ui.render_virtual_text(items, options.format_text),
					virt_text_pos = "eol",
					priority = 1100,
				})
			end
		end
	end

	-- Keep file comments and CodeDiff's deleted rows above line 1 visible.
	for _, pane in ipairs(panes) do
		vim.api.nvim_win_call(pane.win, function()
			local position = vim.fn.winsaveview()
			if position.topline ~= 1 then
				return
			end

			position.topfill = 0
			for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(pane.buf, -1, { 0, 0 }, { 0, -1 }, { details = true })) do
				local details = mark[4]
				---@cast details vim.api.keyset.extmark_details
				if details.virt_lines and details.virt_lines_above then
					position.topfill = position.topfill + #details.virt_lines
				end
			end
			vim.fn.winrestview(position)
		end)
	end

	if view.left.win then
		local leader = vim.api.nvim_get_current_win() == view.left.win and view.left.win or view.right.win
		if has_scroll and scroll.refresh then
			scroll.refresh(view.tabpage, leader)
		else
			vim.api.nvim_win_call(leader, function()
				vim.cmd.syncbind()
			end)
		end
	end
end

---@param view AtlasDiffCodeDiffView
---@param direction 1|-1
---@param kind "comment"|"note"
---@param from_edge boolean|nil
---@return boolean moved
function M.navigate(view, direction, kind, from_edge)
	local rows = {}
	for index, pane in ipairs({ view.left, view.right }) do
		if pane.win then
			rows[index] = view.left.win and native_rows(pane.buf) or {}
		end
	end

	return ui.navigate(view, direction, kind, from_edge, function(pane, line)
		return display_line(line, rows[pane])
	end)
end

return M
