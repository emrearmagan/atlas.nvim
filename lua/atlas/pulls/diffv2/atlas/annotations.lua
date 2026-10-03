local diff = require("atlas.pulls.diffv2.diff")
local render = require("atlas.pulls.diffv2.atlas.render")
local ui = require("atlas.pulls.diffv2.ui.annotations")
local notes = require("atlas.pulls.notes")

local M = {}
local namespace = vim.api.nvim_create_namespace("atlas.diffv2.annotations")

---@param view AtlasDiffV2NativeView
---@param document AtlasDiffV2Document
---@param items AtlasDiffV2Annotation[]
local function place_annotations(view, document, items, expanded)
	local lookup, placed, deleted = {}, {}, {}

	for _, item in ipairs(items) do
		local buf = view.right.buf
		local line = item.line or 1
		local removed = false

		if item.side == "LEFT" then
			if view.left.win then
				buf = view.left.buf
			elseif document.file.status ~= "deleted" and item.line then
				local hunk
				line, hunk = diff.map_line(document.hunks, "LEFT", item.line)
				if hunk then
					removed = true
					line = hunk[4] > 0 and hunk[3] or hunk[3] + 1
					deleted[item.line] = deleted[item.line] or {}
					table.insert(deleted[item.line], item)
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
			local row = expanded and not item.line and 0 or line
			placed[buf] = placed[buf] or {}
			placed[buf][row] = placed[buf][row] or {}
			table.insert(placed[buf][row], item)
		end
	end

	return lookup, placed, deleted
end

---@param view AtlasDiffV2NativeView
local function draw_annotations(view, lookup, placed, hunks, expanded, comment_options)
	for buf, by_line in pairs(lookup) do
		for line in pairs(by_line) do
			vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
				sign_text = "┃",
				sign_hl_group = "AtlasLogInfo",
				number_hl_group = "CursorLineNr",
				priority = 1100,
			})
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

	for buf, by_line in pairs(placed) do
		local pane = buf == view.left.buf and view.left or view.right

		for line, items in pairs(by_line) do
			if expanded then
				local rows = vim.api.nvim_win_call(pane.win, function()
					return ui.render_virtual_lines(items, vim.api.nvim_win_get_width(pane.win), comment_options)
				end)
				put_lines(pane, line, rows, false)

				if view.left.win then
					-- Keep the following diff lines aligned across both panes.
					local side = buf == view.left.buf and "LEFT" or "RIGHT"
					local other = side == "LEFT" and view.right or view.left
					local target = line == 0 and 0 or diff.map_line(hunks, side, line)

					local padding = {}
					for _ = 1, #rows do
						padding[#padding + 1] = { { "", "Normal" } }
					end
					put_lines(other, target, padding, true)
				end
			else
				vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
					virt_text = ui.render_virtual_text(items, comment_options.format_text),
					virt_text_pos = "eol",
					priority = 1100,
				})
			end
		end
	end

	return topfill
end

---@param view AtlasDiffV2NativeView
---@param document AtlasDiffV2Document
---@return table<integer, table<integer, AtlasDiffV2Annotation[]>>
function M.render(view, document)
	M.clear(view.left.buf)
	M.clear(view.right.buf)

	local contents = {
		LEFT = document.contents.old.lines,
		RIGHT = document.contents.new.lines,
	}

	local items = ui.for_file(view.result, document.file)
	local comment_options = ui.comment_options(view.result)
	for _, item in ipairs(items) do
		local count = #contents[item.side]
		if item.thread and (document.binary or (item.line and (item.line < 1 or item.line > count))) then
			item.line = nil
		elseif item.note then
			item.outdated = notes.is_outdated(item.note, contents.RIGHT[item.note.line])
		end
	end

	local expanded = view.result.options.comment_display == "virtual_lines"
	local lookup, placed, deleted = place_annotations(view, document, items, expanded)

	local deleted_topfill = 0
	if not view.left.win then
		deleted_topfill = vim.api.nvim_win_call(view.right.win, function()
			local cards, previews = {}, {}
			local width = vim.api.nvim_win_get_width(view.right.win) - vim.fn.getwininfo(view.right.win)[1].textoff

			for line, entries in pairs(deleted) do
				if expanded then
					cards[line] = ui.render_virtual_lines(entries, width, comment_options)
				else
					previews[line] = ui.render_virtual_text(entries, comment_options.format_text)
				end
			end

			-- Deleted text and its cards share one virtual block.
			return render.deleted_lines(view, contents.LEFT, document.hunks, cards, previews)
		end)
	end

	local topfill = draw_annotations(view, lookup, placed, document.split_hunks, expanded, comment_options)
	if deleted_topfill > 0 then
		topfill[view.right.win] = (topfill[view.right.win] or 0) + deleted_topfill
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

---@param view AtlasDiffV2NativeView
---@param direction 1|-1
---@param kind "comment"|"note"
---@param from_edge boolean|nil
---@return boolean moved
function M.navigate(view, direction, kind, from_edge)
	local document = view.document
	if not document then
		return false
	end

	return ui.navigate(view, direction, kind, from_edge, function(pane, line)
		return view.left.win and diff.display_line(document.split_hunks, pane, line) or line
	end)
end

---@param buf integer
function M.clear(buf)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
end

return M
