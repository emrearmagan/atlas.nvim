local diff = require("atlas.core.git.diff")
local render = require("atlas.pulls.diff.atlas.render")
local annotation_ui = require("atlas.pulls.diff.ui.annotations")

local M = {}
local namespace = vim.api.nvim_create_namespace("atlas.diff.annotations")

---@param renderer AtlasDiffNativeRenderer
---@param document AtlasDiffDocument
---@param items AtlasDiffAnnotation[]
local function place_annotations(renderer, document, items, expanded)
	local lookup, placed, deleted = {}, {}, {}

	for _, item in ipairs(items) do
		local buf = renderer.right.buf
		local line = item.end_line or 1
		local removed = false

		if item.side == "LEFT" then
			if renderer.left.win then
				buf = renderer.left.buf
			elseif document.file.status ~= "deleted" and item.end_line then
				local hunk
				line, hunk = diff.map_line(document.hunks, "LEFT", item.end_line)
				if hunk then
					removed = true
					line = hunk.new_count > 0 and hunk.new_start or hunk.new_start + 1
					deleted[item.end_line] = deleted[item.end_line] or {}
					table.insert(deleted[item.end_line], item)
				end
			end
		end

		-- Deleted virtual lines open their threads from the adjacent real line.
		line = math.max(1, math.min(line, vim.api.nvim_buf_line_count(buf)))
		lookup[buf] = lookup[buf] or {}
		lookup[buf][line] = lookup[buf][line] or {}
		table.insert(lookup[buf][line], item)

		if not removed then
			-- Row zero keeps file-level cards above the first buffer line.
			local row = expanded and not item.end_line and 0 or line
			placed[buf] = placed[buf] or {}
			placed[buf][row] = placed[buf][row] or {}
			table.insert(placed[buf][row], item)
		end
	end

	return lookup, placed, deleted
end

---@param renderer AtlasDiffNativeRenderer
local function draw_annotations(renderer, lookup, placed, hunks, expanded, comment_options)
	for buf, by_line in pairs(lookup) do
		annotation_ui.draw_signs(namespace, buf, by_line)
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

	for buf, by_line in pairs(placed) do
		local pane = buf == renderer.left.buf and renderer.left or renderer.right

		for line, items in pairs(by_line) do
			if expanded then
				local rows = vim.api.nvim_win_call(pane.win, function()
					return annotation_ui.render_virtual_lines(
						items,
						vim.api.nvim_win_get_width(pane.win),
						comment_options
					)
				end)
				put_lines(pane, line, rows, false)

				if renderer.left.win then
					-- Keep the following diff lines aligned across both panes.
					local side = buf == renderer.left.buf and "LEFT" or "RIGHT"
					local other = side == "LEFT" and renderer.right or renderer.left
					local target = line == 0 and 0 or diff.map_line(hunks, side, line)

					local padding = {}
					for _ = 1, #rows do
						padding[#padding + 1] = { { "", "Normal" } }
					end
					put_lines(other, target, padding, true)
				end
			else
				vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
					virt_text = annotation_ui.render_virtual_text(items),
					virt_text_pos = "eol",
					priority = 1100,
				})
			end
		end
	end

	return topfill
end

---@param renderer AtlasDiffNativeRenderer
---@param document AtlasDiffDocument
---@return table<integer, table<integer, AtlasDiffAnnotation[]>>
function M.render(renderer, document)
	M.clear(renderer.left.buf)
	M.clear(renderer.right.buf)

	local contents = {
		LEFT = document.contents.old.lines,
		RIGHT = document.contents.new.lines,
	}

	local items = annotation_ui.for_file(renderer.session, document.file)
	local comment_options = annotation_ui.comment_options(renderer.expanded_threads)
	for _, item in ipairs(items) do
		local count = #contents[item.side]
		if item.thread and (document.binary or (item.end_line and (item.end_line < 1 or item.end_line > count))) then
			item.end_line = nil
		end
	end

	local expanded = renderer.options.comment_display == "virtual_lines"
	local lookup, placed, deleted = place_annotations(renderer, document, items, expanded)

	local deleted_topfill = 0
	if not renderer.left.win then
		deleted_topfill = vim.api.nvim_win_call(renderer.right.win, function()
			local cards, previews = {}, {}
			local width = vim.api.nvim_win_get_width(renderer.right.win)
				- vim.fn.getwininfo(renderer.right.win)[1].textoff

			for line, entries in pairs(deleted) do
				if expanded then
					cards[line] = annotation_ui.render_virtual_lines(entries, width, comment_options)
				else
					previews[line] = annotation_ui.render_virtual_text(entries)
				end
			end

			-- Deleted text and its cards share one virtual block.
			return render.deleted_lines(renderer, contents.LEFT, document.hunks, cards, previews)
		end)
	end

	local topfill = draw_annotations(renderer, lookup, placed, document.split_hunks, expanded, comment_options)
	if deleted_topfill > 0 then
		topfill[renderer.right.win] = (topfill[renderer.right.win] or 0) + deleted_topfill
	end

	-- topfill keeps file comments and deleted rows above line 1 visible.
	for win, count in pairs(topfill) do
		vim.api.nvim_win_call(win, function()
			local position = vim.fn.winsaveview()
			if position.topline == 1 then
				position.topfill = math.max(position.topfill, count + vim.fn.diff_filler(1))
				vim.fn.winrestview(position)
			end
		end)
	end

	return lookup
end

---@param renderer AtlasDiffNativeRenderer
---@param direction 1|-1
---@param kind AtlasDiffAnnotationKind
---@param from_edge boolean|nil
---@return boolean moved
function M.navigate(renderer, direction, kind, from_edge)
	local document = renderer.document
	if not document then
		return false
	end

	return annotation_ui.navigate(renderer, direction, kind, from_edge, function(pane, line)
		return renderer.left.win and diff.display_line(document.split_hunks, pane, line) or line
	end)
end

---@param buf integer
function M.clear(buf)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
end

return M
