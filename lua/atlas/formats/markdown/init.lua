local M = {}

local elements = require("atlas.formats.markdown.elements")
local parse_table = require("atlas.formats.markdown.table")
local highlight_groups = require("atlas.formats.markdown.highlights").groups
local utils = require("atlas.ui.shared.utils")

-- Order matters: checked top to bottom, stopping at the first match.
--
-- "> [!NOTE]" matches both callout and quote, so callout must come first.
-- "* * *" can look like a list item, so rule must come before list.
-- Paragraph matches any line (even "# Title"), so it must stay last.
local block_handlers = {
	elements.block.code,
	elements.block.comment,
	parse_table,
	elements.block.callout,
	elements.block.heading,
	elements.block.rule,
	elements.block.list,
	elements.block.quote,
	elements.block.paragraph,
}

---@class AtlasMarkdownHighlight
---@field line integer Zero-based line.
---@field start_col integer Zero-based byte offset.
---@field end_col integer Exclusive byte offset.
---@field hl_group string

---@class AtlasMarkdownTarget
---@field type "link"|"image"
---@field url string
---@field line integer Zero-based line.
---@field start_col integer Zero-based byte offset.
---@field end_col integer Exclusive byte offset.

-- Maps original Markdown lines to rendered lines in the editor.
-- For example, a table written on 3 lines may take 8 lines after wrapping.
---@class AtlasMarkdownSourceRange
---@field source_start integer
---@field source_end integer
---@field display_start integer
---@field display_end integer

local function append_row(result, row, opts)
	local line = elements.join(row)
	if row.pad then
		local padding = math.max(0, row.pad - vim.fn.strdisplaywidth(line))
		line = line .. string.rep(" ", padding)
	end

	local line_index = #result.lines
	result.lines[line_index + 1] = line

	local function group(style)
		return opts.hl and opts.hl[style] or highlight_groups[style]
	end

	local function highlight(start_col, end_col, hl_group)
		if not hl_group or end_col <= start_col then
			return
		end

		result.highlights[#result.highlights + 1] = {
			line = line_index,
			start_col = start_col,
			end_col = end_col,
			hl_group = hl_group,
		}
	end

	highlight(0, #line, row.hl_group or group(row.hl))

	local column = 0
	for _, fragment in ipairs(row) do
		local next_column = column + #fragment.text
		highlight(column, next_column, group(fragment.background_style))
		highlight(column, next_column, group(fragment.style))

		if fragment.url then
			result.targets[#result.targets + 1] = {
				type = fragment.style,
				url = fragment.url,
				line = line_index,
				start_col = column,
				end_col = next_column,
			}
		end

		column = next_column
	end

	for _, span in ipairs(row.highlights or {}) do
		highlight(span.start_col, span.end_col, span.hl_group)
	end
end

---Parse Markdown into display lines, highlights and link/image targets.
---Width affects tables, rules and code blocks. The UI wraps ordinary text.
---@param source string
---@param opts? { width?: integer, hl?: table<string, string>, source_map?: boolean }
---@return { lines: string[], highlights: AtlasMarkdownHighlight[], targets: AtlasMarkdownTarget[], source_map?: AtlasMarkdownSourceRange[] }
function M.parse(source, opts)
	opts = opts or {}

	local lines = {}
	source = utils.normalize_newlines(source) .. "\n"
	for line in source:gmatch("(.-)\n") do
		lines[#lines + 1] = line
	end

	local result = { lines = {}, highlights = {}, targets = {} }
	if opts.source_map then
		result.source_map = {}
	end
	local width = opts.width
	if width ~= nil and (type(width) ~= "number" or width < 1 or width % 1 ~= 0) then
		result.lines = lines
		return result
	end

	local index = 1

	while index <= #lines do
		local rows, next_index
		for _, parse in ipairs(block_handlers) do
			rows, next_index = parse(lines, index, opts)
			if rows then
				break
			end
		end

		local display_start = #result.lines
		for _, row in ipairs(rows) do
			append_row(result, row, opts)
		end
		if result.source_map then
			result.source_map[#result.source_map + 1] = {
				source_start = index - 1,
				source_end = next_index - 1,
				display_start = display_start,
				display_end = #result.lines,
			}
		end

		index = next_index
	end

	return result
end

return M
