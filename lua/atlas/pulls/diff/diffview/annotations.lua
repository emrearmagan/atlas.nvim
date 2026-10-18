local diff = require("atlas.pulls.diff.diff")
local annotation_ui = require("atlas.pulls.diff.ui.annotations")

local M = {}
local namespace = vim.api.nvim_create_namespace("atlas.diff.diffview.annotations")

---@param renderer AtlasDiffDiffviewRenderer
function M.clear(renderer)
	for buf in pairs(renderer.annotations) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
		end
	end
	renderer.annotations = {}
end

---@param renderer AtlasDiffDiffviewRenderer
function M.render(renderer)
	M.clear(renderer)

	local file = renderer.current_file
	if not file then
		return
	end

	local items = annotation_ui.for_file(renderer.session, file)
	if #items == 0 then
		return
	end

	local layout = renderer.diffview.cur_layout
	local panes = {}
	-- Diffview shares its empty buffer, so don't put cards on missing or binary sides.
	if layout.a and not layout.a.file.nulled and not layout.a.file.binary then
		panes.LEFT = renderer.left
	end
	if not layout.b.file.nulled and not layout.b.file.binary then
		panes.RIGHT = renderer.right
	end

	local expanded = renderer.options.comment_display == "virtual_lines"
	local options = annotation_ui.comment_options(renderer.expanded_threads)
	local placed = {}
	for _, pane in pairs(panes) do
		renderer.annotations[pane.buf] = {}
		placed[pane.buf] = {}
	end

	for _, item in ipairs(items) do
		local pane = panes[item.side]
		if pane then
			local count = vim.api.nvim_buf_line_count(pane.buf)
			if item.thread and item.end_line and (item.end_line < 1 or item.end_line > count) then
				item.end_line = nil
			end

			local line = math.max(1, math.min(item.end_line or 1, count))
			local lookup = renderer.annotations[pane.buf]
			lookup[line] = lookup[line] or {}
			table.insert(lookup[line], item)

			local row = expanded and not item.end_line and 0 or line
			placed[pane.buf][row] = placed[pane.buf][row] or {}
			table.insert(placed[pane.buf][row], item)
		end
	end

	local topfill = {}
	local function put_lines(pane, line, rows, padding)
		local row = math.max(1, math.min(line, vim.api.nvim_buf_line_count(pane.buf))) - 1
		vim.api.nvim_buf_set_extmark(pane.buf, namespace, row, 0, {
			virt_lines = rows,
			virt_lines_above = line < 1,
			virt_lines_leftcol = true,
			priority = padding and 1090 or 1100,
		})

		if line < 1 then
			topfill[pane.win] = (topfill[pane.win] or 0) + #rows
		end
	end

	for side, pane in pairs(panes) do
		annotation_ui.draw_signs(namespace, pane.buf, renderer.annotations[pane.buf])

		for line, entries in pairs(placed[pane.buf]) do
			if expanded then
				local rows = vim.api.nvim_win_call(pane.win, function()
					return annotation_ui.render_virtual_lines(entries, vim.api.nvim_win_get_width(pane.win), options)
				end)
				put_lines(pane, line, rows, false)

				local other = panes[side == "LEFT" and "RIGHT" or "LEFT"]
				if other then
					-- Keep the diff lines below each card aligned across the panes.
					local target = line == 0 and 0 or diff.map_line(renderer.split_hunks, side, line)
					local padding = {}
					for _ = 1, #rows do
						padding[#padding + 1] = { { "", "Normal" } }
					end
					put_lines(other, target, padding, true)
				end
			else
				vim.api.nvim_buf_set_extmark(pane.buf, namespace, line - 1, 0, {
					virt_text = annotation_ui.render_virtual_text(entries),
					virt_text_pos = "eol",
					priority = 1100,
				})
			end
		end
	end

	-- Keep one pane's scroll adjustment from hiding the other's file comments.
	local scrollbind = {}
	for _, pane in pairs(panes) do
		scrollbind[pane.win] = vim.wo[pane.win].scrollbind
		vim.wo[pane.win].scrollbind = false
	end

	-- Keep file comments above line 1 visible.
	for _, pane in pairs(panes) do
		vim.api.nvim_win_call(pane.win, function()
			local position = vim.fn.winsaveview()
			if position.topline == 1 then
				position.topfill = (topfill[pane.win] or 0) + vim.fn.diff_filler(1)
				vim.fn.winrestview(position)
			end
		end)
	end
	-- Apply both positions before scrollbind resumes.
	vim.cmd.redraw()
	for win, value in pairs(scrollbind) do
		vim.wo[win].scrollbind = value
	end
end

---@param renderer AtlasDiffDiffviewRenderer
---@param direction 1|-1
---@param kind AtlasDiffAnnotationKind
---@param from_edge boolean|nil
---@return boolean moved
function M.navigate(renderer, direction, kind, from_edge)
	if renderer.pending_file then
		return false
	end

	return annotation_ui.navigate(renderer, direction, kind, from_edge, function(pane, line)
		return diff.display_line(renderer.split_hunks, pane, line)
	end)
end

return M
