local M = {}

---@param lines string[]
---@param highlights AtlasUIHighlight[]|nil
---@param opts { width: integer|nil, background_hl_group: string|nil }|nil
---@return [string, string|string[]][][]
function M.render(lines, highlights, opts)
	opts = opts or {}
	local spans_by_line, backgrounds = {}, {}
	for _, highlight in ipairs(highlights or {}) do
		local line = highlight.line + 1
		if highlight.line_hl_group then
			backgrounds[line] = highlight.line_hl_group
		else
			spans_by_line[line] = spans_by_line[line] or {}
			table.insert(spans_by_line[line], highlight)
		end
	end

	local result = {}
	for line_number, source in ipairs(lines) do
		local width = vim.fn.strdisplaywidth(source)
		local line = source
		if opts.width and width < opts.width then
			line = line .. string.rep(" ", opts.width - width)
		end
		local spans = spans_by_line[line_number] or {}
		local background = backgrounds[line_number] or opts.background_hl_group

		-- A virtual-text chunk can only have one highlight stack, so split where a span starts or ends.
		local columns = { 0, #line }
		for _, span in ipairs(spans) do
			table.insert(columns, span.start_col)
			table.insert(columns, span.end_col)
		end
		table.sort(columns)

		local chunks = {}
		for index = 1, #columns - 1 do
			local start_col, end_col = columns[index], columns[index + 1]
			if end_col > start_col then
				local groups = {}
				for _, span in ipairs(spans) do
					if span.start_col <= start_col and span.end_col >= end_col then
						table.insert(groups, span.hl_group)
					end
				end
				if background then
					table.insert(groups, background)
				end
				local group = "Normal"
				if #groups == 1 then
					group = groups[1]
				elseif #groups > 1 then
					group = groups
				end
				table.insert(chunks, { line:sub(start_col + 1, end_col), group })
			end
		end
		result[line_number] = chunks
	end
	return result
end

return M
