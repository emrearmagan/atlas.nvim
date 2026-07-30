local M = {}

local namespace = vim.api.nvim_create_namespace("atlas_native_diff")
local CONTEXT_LINES = 3

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
---@param line_count integer
---@return { first: integer, last: integer }[]
local function visible_ranges(hunks, line_count)
	local ranges = {}
	for _, hunk in ipairs(hunks) do
		local first = math.max(1, math.min(line_count, hunk.new_start))
		local last = hunk.new_count > 0 and hunk.new_start + hunk.new_count - 1 or first
		table.insert(ranges, {
			first = math.max(1, first - CONTEXT_LINES),
			last = math.min(line_count, math.max(first, last + CONTEXT_LINES)),
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

---@param win integer
---@param ranges { first: integer, last: integer }[]
---@param line_count integer
local function apply_folds(win, ranges, line_count)
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	vim.api.nvim_win_call(win, function()
		vim.wo[win][0].foldmethod = "manual"
		vim.cmd("silent! normal! zE")
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
		vim.wo[win][0].foldenable = true
		vim.wo[win][0].foldlevel = 0
	end)
end

---@param document AtlasNativeDiffDocument
---@param buf integer
---@param win integer
function M.file(document, buf, win)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	local hunks = document.file.hunks
	if not document.binary then
		for _, hunk in ipairs(hunks) do
			if hunk.new_count > 0 then
				highlight_lines(buf, hunk.new_start, hunk.new_count, "AtlasDiffAddLine")
			end
			if hunk.old_count > 0 then
				local virtual_lines = {}
				for line = hunk.old_start, hunk.old_start + hunk.old_count - 1 do
					table.insert(virtual_lines, {
						{ "- ", "AtlasDiffRemoveMarker" },
						{ document.old.lines[line] or "", "AtlasDiffRemoveLine" },
					})
				end
				local line_count = vim.api.nvim_buf_line_count(buf)
				local anchor, above
				if hunk.new_count > 0 then
					anchor, above = math.max(0, hunk.new_start - 1), true
				elseif hunk.new_start < line_count then
					anchor, above = math.max(0, hunk.new_start), true
				else
					anchor, above = math.max(0, line_count - 1), false
				end
				vim.api.nvim_buf_set_extmark(buf, namespace, anchor, 0, {
					virt_lines = virtual_lines,
					virt_lines_above = above,
					virt_lines_leftcol = true,
					priority = 90,
				})
			end
		end
	end

	local options = vim.wo[win][0]
	options.foldcolumn = "0"
	options.signcolumn = "no"
	local line_count = vim.api.nvim_buf_line_count(buf)
	if document.binary or #hunks == 0 then
		apply_folds(win, {}, line_count)
		vim.wo[win][0].foldenable = false
		return
	end
	apply_folds(win, visible_ranges(hunks, line_count), line_count)
end

return M
