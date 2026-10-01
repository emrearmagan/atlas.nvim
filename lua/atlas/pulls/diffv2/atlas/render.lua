local M = {}
local namespace = vim.api.nvim_create_namespace("atlas.diffv2.inline")
local deleted_namespace = vim.api.nvim_create_namespace("atlas.diffv2.deleted")

local function highlight(buf, first, count, group)
	for line = first, first + count - 1 do
		vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, { line_hl_group = group, priority = 100 })
	end
end

local function fold_inline(win, hunks, line_count)
	local context = tonumber(vim.o.diffopt:match("context:(%d+)")) or 6
	vim.api.nvim_win_call(win, function()
		local options = vim.wo[0][0]
		options.foldlevel = 0
		options.foldminlines = 1

		local next_line = 1
		for _, hunk in ipairs(hunks) do
			local start, count = hunk[3], hunk[4]
			if count == 0 then
				start = start + 1
				if context == 0 then
					-- Keep the anchor visible so deleted virtual lines don't disappear into a fold.
					start = math.min(start, line_count)
					count = 1
				end
			end

			local first = math.max(1, start - context)
			local last = math.min(line_count, start + count - 1 + context)
			if next_line < first then
				vim.cmd.fold({ range = { next_line, first - 1 } })
			end
			next_line = math.max(next_line, last + 1)
		end

		if next_line <= line_count then
			vim.cmd.fold({ range = { next_line, line_count } })
		end
	end)
end

---@param view AtlasDiffV2NativeView
---@param document AtlasDiffV2Document
local function render_inline(view, document)
	local buf = view.right.buf
	local file = document.file

	vim.api.nvim_win_call(view.right.win, function()
		local options = vim.wo[0][0]
		options.foldmethod = "manual"
		options.foldenable = false
		vim.cmd("normal! zE")
	end)
	vim.api.nvim_win_set_cursor(view.right.win, { 1, 0 })

	if document.binary then
		return
	end

	if file.status == "added" or file.status == "deleted" then
		view.inline_hunk_lines = { 1 }
		local group = file.status == "added" and "DiffAdd" or "DiffDelete"
		highlight(buf, 1, vim.api.nvim_buf_line_count(buf), group)
		return
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	for _, hunk in ipairs(document.hunks) do
		local new_start, new_count = hunk[3], hunk[4]
		local target = new_count > 0 and new_start or new_start + 1
		view.inline_hunk_lines[#view.inline_hunk_lines + 1] = math.min(target, line_count)
		highlight(buf, new_start, new_count, "DiffAdd")
	end

	if #document.hunks > 0 then
		fold_inline(view.right.win, document.hunks, line_count)
	end
end

---@param view AtlasDiffV2NativeView
---@param old_lines string[]
---@param hunks integer[][]
---@param cards table<integer, [string, string|string[]][][]>
---@param previews table<integer, [string, string][]>
---@return integer
function M.deleted_lines(view, old_lines, hunks, cards, previews)
	local buf = view.right.buf
	vim.api.nvim_buf_clear_namespace(buf, deleted_namespace, 0, -1)

	local line_count = vim.api.nvim_buf_line_count(buf)
	local width = vim.api.nvim_win_get_width(view.right.win) - vim.fn.getwininfo(view.right.win)[1].textoff
	local topfill = 0

	for _, hunk in ipairs(hunks) do
		local old_start, old_count, new_start, new_count = unpack(hunk)

		if old_count > 0 then
			local rows = {}
			for line = old_start, old_start + old_count - 1 do
				local chunks = { { old_lines[line], "DiffDelete" } }
				if previews[line] then
					vim.list_extend(chunks, previews[line])
				end

				-- Blank removed lines need a background too.
				local used = 0
				for _, chunk in ipairs(chunks) do
					used = used + vim.fn.strdisplaywidth(chunk[1], used)
				end

				chunks[#chunks + 1] = { string.rep(" ", math.max(0, width - used)), "DiffDelete" }
				rows[#rows + 1] = chunks

				if cards[line] then
					vim.list_extend(rows, cards[line])
				end
			end

			local anchor = new_count > 0 and new_start - 1 or new_start
			vim.api.nvim_buf_set_extmark(buf, deleted_namespace, math.min(anchor, line_count - 1), 0, {
				virt_lines = rows,
				virt_lines_above = anchor < line_count,
				virt_lines_overflow = vim.fn.has("nvim-0.11") == 1 and "scroll" or nil,
			})

			if anchor == 0 then
				topfill = topfill + #rows
			end
		end
	end

	return topfill
end

---@param view AtlasDiffV2NativeView
local function render_side_by_side(view, binary)
	for _, pane in ipairs({ view.left, view.right }) do
		vim.api.nvim_win_call(pane.win, function()
			vim.cmd(binary and "diffoff" or "diffthis")
			local options = vim.wo[0][0]
			options.foldenable = false
			options.foldminlines = 1
			options.wrap = false

			options.winhighlight = vim.go.winhighlight
			vim.opt_local.winhighlight:append("DiffDelete:Comment")
			if pane == view.left then
				vim.opt_local.winhighlight:append("DiffAdd:DiffDelete")
			end
			vim.api.nvim_win_set_cursor(pane.win, { 1, 0 })
		end)
	end

	if not binary then
		vim.api.nvim_win_call(view.right.win, function()
			vim.cmd.diffupdate()
			vim.cmd.syncbind()
		end)
	end
end

---@param view AtlasDiffV2NativeView
---@param document AtlasDiffV2Document
function M.compact(view, document)
	local compact = view.result.options.compact
		and not document.binary
		and document.file.status ~= "added"
		and document.file.status ~= "deleted"

	for _, pane in ipairs({ view.left, view.right }) do
		if pane.win then
			vim.api.nvim_win_call(pane.win, function()
				vim.wo.foldenable = compact
				if compact then
					vim.cmd("normal! zM")
				end
			end)
		end
	end
end

---@param view AtlasDiffV2NativeView
---@param document AtlasDiffV2Document
function M.render(view, document)
	view.inline_hunk_lines = {}
	M.clear(view.left.buf)
	M.clear(view.right.buf)

	if view.left.win then
		render_side_by_side(view, document.binary)
	else
		render_inline(view, document)
	end

	M.compact(view, document)

	-- Start at the first change in both layouts.
	local first = document.split_hunks[1]
	if view.left.win and first then
		for _, pane in ipairs({ view.left, view.right }) do
			local side = pane == view.left and 1 or 3
			local line = first[side]
			if first[side + 1] == 0 then
				line = line + 1
			end
			line = math.min(line, vim.api.nvim_buf_line_count(pane.buf))
			vim.api.nvim_win_set_cursor(pane.win, { line, 0 })
		end
	elseif view.inline_hunk_lines[1] then
		vim.api.nvim_win_set_cursor(view.right.win, { view.inline_hunk_lines[1], 0 })
	end
end

---@param buf integer
function M.clear(buf)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	vim.api.nvim_buf_clear_namespace(buf, deleted_namespace, 0, -1)
end

return M
