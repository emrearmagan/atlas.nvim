local elements = require("atlas.formats.markdown.elements")

-- Border rows: { left, junction, right }. Each symbol must occupy one cell.
local borders = {
	horizontal = "-",
	vertical = "|",
	top = { "|", "|", "|" },
	middle = { "|", "|", "|" },
	bottom = { "|", "|", "|" },
}

-- | a\|b | `c|d` | -> { "a\|b", "`c|d`" }.
local function split_cells(line)
	line = vim.trim(line)
	local cells = {}
	local cell_start = 1
	local position = 1

	while position <= #line do
		local character = line:sub(position, position)
		if character == "\\" then
			position = position + 2
		elseif character == "`" then
			local remaining = line:sub(position)
			local delimiter = remaining:match("^(`+)")
			local closing_position = remaining:find(delimiter, #delimiter + 1, true)
			if closing_position then
				position = position + closing_position + #delimiter - 1
			else
				position = position + #delimiter
			end
		elseif character == "|" then
			cells[#cells + 1] = vim.trim(line:sub(cell_start, position - 1))
			position = position + 1
			cell_start = position
		else
			position = position + 1
		end
	end

	if #cells == 0 then
		return
	end

	cells[#cells + 1] = vim.trim(line:sub(cell_start))
	if line:sub(1, 1) == "|" then
		table.remove(cells, 1)
	end
	if cell_start == #line + 1 then
		table.remove(cells)
	end

	return cells
end

-- { 3, 4 } -> a "|-----|------|" separator row.
local function divider(column_widths, padding, edges)
	local segments = {}
	for column, width in ipairs(column_widths) do
		segments[column] = string.rep(borders.horizontal, width + 2 * padding)
	end

	return { { text = edges[1] .. table.concat(segments, edges[2]) .. edges[3], style = "table_border" } }
end

-- Columns cannot shrink below their widest character.
local function fit_columns(widths, minimums, width)
	if not width then
		return 1
	end

	local minimum_width = 0
	for _, value in ipairs(minimums) do
		minimum_width = minimum_width + value
	end

	local border_width = #widths + 1
	local padding = width >= minimum_width + border_width + 2 * #widths and 1 or 0
	local content_width = math.max(minimum_width, width - border_width - 2 * padding * #widths)
	local total_width = 0
	for column, value in ipairs(widths) do
		widths[column] = math.min(value, content_width - minimum_width + minimums[column])
		total_width = total_width + widths[column]
	end

	while total_width > content_width do
		local widest
		for column, value in ipairs(widths) do
			if value > minimums[column] and (not widest or value > widths[widest]) then
				widest = column
			end
		end

		widths[widest] = widths[widest] - 1
		total_width = total_width - 1
	end

	return padding
end

-- Slice by byte offsets.
local function slice(fragments, first, last)
	local result = {}
	local offset = 0

	for _, fragment in ipairs(fragments) do
		local finish = offset + #fragment.text

		if finish >= first and offset < last then
			local content = fragment.text:sub(math.max(1, first - offset), math.min(#fragment.text, last - offset))
			result[#result + 1] = {
				text = content,
				style = fragment.style,
				background_style = fragment.background_style,
				url = fragment.url,
			}
		end

		offset = finish
		if offset >= last then
			break
		end
	end

	return result
end

-- { { text = "Hello " }, { text = "world", style = "strong" } }, width 5.
-- Two rows, "Hello" and "world".
-- The column width must fit its widest character.
local function wrap(fragments, width)
	local content = elements.join(fragments)
	if vim.fn.strdisplaywidth(content) <= width then
		return { fragments }
	end

	local characters = {}
	for first, character, next_byte in content:gmatch("()([%z\1-\127\194-\244][\128-\191]*)()") do
		characters[#characters + 1] = {
			first = first,
			last = next_byte - 1,
			width = vim.fn.strdisplaywidth(character),
			space = character:match("%s") ~= nil,
		}
	end

	local rows = {}
	local first = 1

	while first <= #characters do
		local position = first
		local used_width = 0
		local last_space

		while position <= #characters do
			local character = characters[position]
			if character.space then
				last_space = position
			end

			if used_width + character.width > width then
				break
			end

			used_width = used_width + character.width
			position = position + 1
		end

		local last = position - 1
		if position <= #characters and last_space then
			last = last_space - 1
			position = last_space + 1

			while last >= first and characters[last].space do
				last = last - 1
			end
			while position <= #characters and characters[position].space do
				position = position + 1
			end
		end

		if last >= first then
			rows[#rows + 1] = slice(fragments, characters[first].first, characters[last].last)
		end
		first = position
	end

	return rows
end

-- A cell containing "one two" at width 3 produces aligned "one"/"two" rows.
local function layout_row(cells, column_widths, alignment, cell_padding, fill)
	local wrapped_cells = {}
	local height = 1
	for column, width in ipairs(column_widths) do
		wrapped_cells[column] = wrap(cells[column], width)
		height = math.max(height, #wrapped_cells[column])
	end

	local rows = {}
	for line = 1, height do
		local row = { { text = borders.vertical, style = "table_border" } }
		for column, width in ipairs(column_widths) do
			local fragments = wrapped_cells[column][line] or {}
			local padding = width - vim.fn.strdisplaywidth(elements.join(fragments))
			local left_padding = 0
			if alignment[column] == "right" then
				left_padding = padding
			elseif alignment[column] == "center" then
				left_padding = math.floor(padding / 2)
			end

			row[#row + 1] = { text = string.rep(" ", left_padding + cell_padding), style = fill }
			for _, fragment in ipairs(fragments) do
				fragment.background_style = fill
				row[#row + 1] = fragment
			end
			row[#row + 1] = { text = string.rep(" ", padding - left_padding + cell_padding), style = fill }
			row[#row + 1] = { text = borders.vertical, style = "table_border" }
		end

		rows[#rows + 1] = row
	end

	return rows
end

--   | Name |
--   | --- |
--   | Ada |
--
--   |------|
--   | Name |
--   |------|
--   | Ada  |
--   |------|
local function parse(lines, index, opts)
	local header = split_cells(lines[index])
	if not header or #header == 0 or not lines[index + 1] then
		return
	end

	local separator = split_cells(lines[index + 1])
	if not separator or #header ~= #separator then
		return
	end

	local alignment = {}
	for column, cell in ipairs(separator) do
		if not cell:match("^:?-+:?$") then
			return
		end

		if cell:sub(1, 1) == ":" and cell:sub(-1) == ":" then
			alignment[column] = "center"
		elseif cell:sub(-1) == ":" then
			alignment[column] = "right"
		else
			alignment[column] = "left"
		end
	end

	local cell_rows = { header }
	local column_count = #header
	index = index + 2

	while index <= #lines do
		local cells = split_cells(lines[index])
		if not cells then
			break
		end

		cell_rows[#cell_rows + 1] = cells
		column_count = math.max(column_count, #cells)
		index = index + 1
	end

	local column_widths, minimums = {}, {}
	for column = 1, column_count do
		column_widths[column] = 1
		minimums[column] = 1
	end

	for _, row in ipairs(cell_rows) do
		for column = 1, column_count do
			local fragments = elements.parse_inline(row[column] or "")
			row[column] = fragments
			local content = elements.join(fragments)
			column_widths[column] = math.max(column_widths[column], vim.fn.strdisplaywidth(content))
			for character in content:gmatch(".[\128-\191]*") do
				minimums[column] = math.max(minimums[column], vim.fn.strdisplaywidth(character))
			end
		end
	end

	local cell_padding = fit_columns(column_widths, minimums, opts.width)
	local rendered_rows = { divider(column_widths, cell_padding, borders.top) }
	for row_index, cells in ipairs(cell_rows) do
		local fill
		if row_index == 1 then
			fill = "table_header"
		elseif row_index % 2 == 1 then
			fill = "table_row"
		end

		vim.list_extend(rendered_rows, layout_row(cells, column_widths, alignment, cell_padding, fill))

		if row_index == 1 then
			rendered_rows[#rendered_rows + 1] = divider(column_widths, cell_padding, borders.middle)
		end
	end

	rendered_rows[#rendered_rows + 1] = divider(column_widths, cell_padding, borders.bottom)
	return rendered_rows, index
end

return parse
