local M = {}

local namespace = vim.api.nvim_create_namespace("atlas_native_diff")
local inline_namespace = vim.api.nvim_create_namespace("atlas_native_diff_inline")

---@class AtlasDiffFileRenderOptions
---@field layout "side-by-side"|"inline"
---@field compact boolean
---@field compact_context_lines integer
---@field left { buf: integer, win: integer|nil }
---@field right { buf: integer, win: integer|nil }

---@class AtlasDiffVisibleRange
---@field first integer
---@field last integer

---@param buf integer
---@param first integer
---@param count integer
---@param highlight string
local function highlight_lines(buf, first, count, highlight)
	for line = math.max(1, first), math.max(0, first + count - 1) do
		if line <= vim.api.nvim_buf_line_count(buf) then
			vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
				line_hl_group = highlight,
				priority = 100,
			})
		end
	end
end

-- Keep each hunk and a little context open in compact mode.
---@param hunks DiffHunk[]
---@param side "old"|"new"
---@param line_count integer
---@param context_lines integer
---@return AtlasDiffVisibleRange[]
local function visible_ranges(hunks, side, line_count, context_lines)
	local ranges = {}
	for _, hunk in ipairs(hunks) do
		local start = side == "old" and hunk.old_start or hunk.new_start
		local count = side == "old" and hunk.old_count or hunk.new_count
		local first = math.max(1, math.min(line_count, start))
		local last = count > 0 and start + count - 1 or first
		table.insert(ranges, {
			first = math.max(1, first - context_lines),
			last = math.min(line_count, math.max(first, last + context_lines)),
		})
	end
	table.sort(ranges, function(left, right)
		return left.first < right.first
	end)
	local merged = {}
	for _, range in ipairs(ranges) do
		local previous = merged[#merged]
		if previous and range.first <= previous.last + 1 then
			previous.last = math.max(previous.last, range.last)
		else
			table.insert(merged, range)
		end
	end
	return merged
end

---@param win integer|nil
---@param ranges AtlasDiffVisibleRange[]
---@param line_count integer
---@param compact boolean
local function apply_folds(win, ranges, line_count, compact)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	vim.api.nvim_win_call(win, function()
		local view = vim.fn.winsaveview()
		vim.wo[win][0].foldmethod = "manual"
		vim.cmd("silent! normal! zE")
		if compact then
			local next_line = 1
			for _, range in ipairs(ranges) do
				if next_line < range.first then
					vim.cmd(string.format("silent! %d,%dfold", next_line, range.first - 1))
				end
				next_line = range.last + 1
			end
			if next_line <= line_count then
				vim.cmd(string.format("silent! %d,%dfold", next_line, line_count))
			end
		end
		vim.wo[win][0].foldenable = compact
		vim.wo[win][0].foldlevel = 0
		pcall(vim.fn.winrestview, view)
	end)
end

---@param document AtlasNativeDiffDocument
---@param right_buf integer
---@param comments? table<integer, [string, string][][]>
function M.inline_deleted_lines(document, right_buf, comments)
	vim.api.nvim_buf_clear_namespace(right_buf, inline_namespace, 0, -1)
	if document.binary then
		return
	end
	local win = vim.fn.win_findbuf(right_buf)[1]
	local textoff = win and vim.fn.getwininfo(win)[1].textoff or 0
	for _, hunk in ipairs(document.changes) do
		if hunk.old_count > 0 then
			local virtual_lines = {}
			for line = hunk.old_start, hunk.old_start + hunk.old_count - 1 do
				table.insert(virtual_lines, {
					{ string.rep(" ", textoff), "Normal" },
					{ document.old.lines[line] or "", "AtlasDiffRemoveLine" },
				})
				vim.list_extend(virtual_lines, (comments and comments[line]) or {})
			end
			local line_count = vim.api.nvim_buf_line_count(right_buf)
			local anchor, above
			if hunk.new_count > 0 then
				anchor, above = math.max(0, hunk.new_start - 1), true
			elseif hunk.new_start < line_count then
				anchor, above = math.max(0, hunk.new_start), true
			else
				anchor, above = math.max(0, line_count - 1), false
			end
			vim.api.nvim_buf_set_extmark(right_buf, inline_namespace, anchor, 0, {
				virt_lines = virtual_lines,
				virt_lines_above = above,
				virt_lines_leftcol = true,
				priority = 90,
			})
		end
	end
end

---@param document AtlasNativeDiffDocument
---@param opts AtlasDiffFileRenderOptions
function M.file(document, opts)
	local left_buf = opts.left.buf
	local right_buf = opts.right.buf
	vim.api.nvim_buf_clear_namespace(left_buf, namespace, 0, -1)
	vim.api.nvim_buf_clear_namespace(right_buf, namespace, 0, -1)
	vim.api.nvim_buf_clear_namespace(right_buf, inline_namespace, 0, -1)
	local hunks = document.changes
	if not document.binary then
		for _, hunk in ipairs(hunks) do
			if hunk.old_count > 0 then
				highlight_lines(left_buf, hunk.old_start, hunk.old_count, "AtlasDiffRemoveLine")
			end
			if hunk.new_count > 0 then
				highlight_lines(right_buf, hunk.new_start, hunk.new_count, "AtlasDiffAddLine")
			end
		end
	end
	if opts.layout == "inline" then
		M.inline_deleted_lines(document, right_buf)
	end

	local compact = opts.compact and not document.binary and #hunks > 0
	local left_count = vim.api.nvim_buf_line_count(left_buf)
	local right_count = vim.api.nvim_buf_line_count(right_buf)
	local context_lines = opts.compact_context_lines
	apply_folds(opts.left.win, visible_ranges(hunks, "old", left_count, context_lines), left_count, compact)
	apply_folds(opts.right.win, visible_ranges(hunks, "new", right_count, context_lines), right_count, compact)
end

return M
