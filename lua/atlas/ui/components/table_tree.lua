local M = {}

local utils = require("atlas.ui.shared.utils")
local ui_utils = require("atlas.ui.utils")

local display_width = ui_utils.text_width
local pad_aligned = ui_utils.pad_aligned

local function truncate(text, width, from_start)
	return utils.truncate(tostring(text or ""), width, from_start)
end

---@class TableTreeTreeOpts
---@field column_key string Column key that receives tree indent + branch/leaf glyphs.
---@field children_key? string Default "children".
---@field expanded_field? string Default "expanded".
---@field default_expanded? boolean When row has no expanded field.
---@field indent? string Per depth level (default "  ").
---@field leaf_prefix? string For non-branch rows at depth > 0 (default "└─ ").
---@field show_indicator? boolean Branch expand/collapse glyphs (default true).
---@field separator? string If set, inserts a full-width separator line between root siblings.
---@field is_expanded? fun(row:table):boolean Overrides expanded_field when set.

---@param tree TableTreeTreeOpts|nil
---@return TableTreeTreeOpts|nil
local function resolve_tree(tree)
	if type(tree) ~= "table" or tree.column_key == nil or tree.column_key == "" then
		return nil
	end

	return {
		column_key = tree.column_key,
		children_key = tree.children_key or "children",
		expanded_field = tree.expanded_field or "expanded",
		default_expanded = tree.default_expanded == true,
		indent = tree.indent or "  ",
		leaf_prefix = tree.leaf_prefix or "└─ ",
		show_indicator = tree.show_indicator ~= false,
		separator = tree.separator,
		is_expanded = tree.is_expanded,
	}
end

---@param row table
---@param has_children boolean
---@param tree TableTreeTreeOpts
---@return boolean
local function row_is_expanded(row, has_children, tree)
	if not has_children then
		return false
	end
	if tree.is_expanded then
		return tree.is_expanded(row) == true
	end
	if row[tree.expanded_field] ~= nil then
		return row[tree.expanded_field] == true
	end
	return tree.default_expanded
end

---@param row table
---@return boolean
local function is_pass_through_row(row)
	if row == nil then
		return true
	end
	if row.kind == "separator" then
		return true
	end
	if row._tv2_pass_through == true then
		return true
	end
	return false
end

---@param rows table[]
---@param tree TableTreeTreeOpts|nil
---@return table[]
local function flatten(rows, tree)
	if tree == nil then
		local out = {}
		for _, row in ipairs(rows or {}) do
			table.insert(
				out,
				vim.tbl_extend("force", row, {
					_tv2_depth = 0,
					_tv2_has_children = false,
					_tv2_expanded = false,
				})
			)
		end
		return out
	end

	local out = {}
	local root_count = #(rows or {})

	local function walk(list, depth)
		for index, row in ipairs(list or {}) do
			if is_pass_through_row(row) then
				table.insert(
					out,
					vim.tbl_extend("force", row, {
						_tv2_depth = 0,
						_tv2_has_children = false,
						_tv2_expanded = false,
					})
				)
			else
				local children = row[tree.children_key]
				local has_children = type(children) == "table" and #children > 0
				local expanded = row_is_expanded(row, has_children, tree)
				table.insert(
					out,
					vim.tbl_extend("force", row, {
						_tv2_depth = depth,
						_tv2_has_children = has_children,
						_tv2_expanded = expanded,
					})
				)

				if has_children and expanded then
					walk(children, depth + 1)
				end

				if depth == 0 and tree.separator ~= nil and tree.separator ~= "" and index < root_count then
					table.insert(out, {
						_tv2_separator = true,
						_tv2_separator_char = tree.separator,
					})
				end
			end
		end
	end

	walk(rows, 0)
	return out
end

---@param row table
---@param tree TableTreeTreeOpts
---@return string
local function tree_glyphs_for_row(row, tree)
	local level = row._tv2_depth or 0
	local indent = string.rep(tree.indent, level)

	if not tree.show_indicator then
		if level == 0 then
			return ""
		end
		return indent .. tree.leaf_prefix
	end

	if row._tv2_has_children then
		return indent .. (row._tv2_expanded and "▾ " or "▸ ")
	end

	if level == 0 then
		return "  "
	end

	return indent .. tree.leaf_prefix
end

---@param row table
---@param column table
---@param tree TableTreeTreeOpts|nil
---@return string
local function cell_text(row, column, tree)
	local raw = tostring(row[column.key] or ""):gsub("%c", " ")
	if tree == nil or column.key ~= tree.column_key then
		return raw
	end
	return tree_glyphs_for_row(row, tree) .. raw
end

---@param column table
---@param rows table[]
---@param tree TableTreeTreeOpts|nil
local function natural_width(column, rows, tree)
	if column.width then
		return column.width
	end

	local w = display_width(column.name or column.key or "")
	for _, row in ipairs(rows) do
		if not row._tv2_separator then
			w = math.max(w, display_width(cell_text(row, column, tree)))
		end
	end

	if column.min_width ~= nil then
		w = math.max(w, column.min_width)
	end

	return w
end

---@param columns table[]
---@param rows table[]
---@param available_width number
---@param gap_after fun(index:number):number
---@param tree TableTreeTreeOpts|nil
---@param fill boolean|nil
local function compute_widths(columns, rows, available_width, gap_after, tree, fill)
	local widths = {}
	for i, c in ipairs(columns) do
		widths[i] = natural_width(c, rows, tree)
	end
	local desired = vim.deepcopy(widths)

	local function total_used()
		local sum = 0
		for _, w in ipairs(widths) do
			sum = sum + w
		end
		for i = 1, math.max(#columns - 1, 0) do
			sum = sum + gap_after(i)
		end
		return sum
	end

	while total_used() > available_width do
		local widest_idx = nil
		local widest_width = -1

		for i, col in ipairs(columns) do
			if not col.width and widths[i] > widest_width and widths[i] > 1 then
				widest_idx = i
				widest_width = widths[i]
			end
		end

		if widest_idx == nil then
			break
		end

		widths[widest_idx] = widths[widest_idx] - 1
	end

	if fill ~= false then
		while total_used() < available_width do
			local smallest_idx = nil
			local smallest_width = math.huge

			for i, col in ipairs(columns) do
				if not col.width and col.can_grow ~= false then
					local is_last = (i == #columns)
					local allow_grow_last = col.grow_last == true
					local capped_by_last = is_last and not allow_grow_last and widths[i] >= desired[i]
					local capped_by_max = col.max_width ~= nil and widths[i] >= col.max_width

					if not capped_by_last and not capped_by_max then
						if widths[i] < smallest_width then
							smallest_idx = i
							smallest_width = widths[i]
						end
					end
				end
			end

			if smallest_idx == nil then
				break
			end

			widths[smallest_idx] = widths[smallest_idx] + 1
		end
	end

	for i, c in ipairs(columns) do
		c._computed = widths[i]
	end
end

---@class TableTreeRenderOpts
---@field columns table[]
---@field rows table[]
---@field width? integer
---@field margin? integer
---@field show_header? boolean
---@field column_gap? integer
---@field fill? boolean
---@field tree? TableTreeTreeOpts
---@field cell_hl? fun(row:table, col:table, ctx:{text:string, padded:string, width:integer}):string|table[]|nil
---@field align_title? boolean If true and header_align is nil, header uses column align.

---@param opts TableTreeRenderOpts
---@return string[] lines
---@return table<integer, table> line_map
---@return table[] spans
function M.render(opts)
	local columns = vim.deepcopy(opts.columns or {})
	local tree = resolve_tree(opts.tree)
	local rows = flatten(opts.rows or {}, tree)
	local width = opts.width or vim.o.columns
	local margin = opts.margin or 2
	local show_header = opts.show_header ~= false
	local cell_hl = opts.cell_hl
	local default_gap = opts.column_gap or 2
	local fill = opts.fill

	local function gap_after(index)
		local c = columns[index]
		if not c then
			return default_gap
		end
		if c.gap_after ~= nil then
			return c.gap_after
		end
		return default_gap
	end

	local function join_parts(parts)
		if #parts == 0 then
			return ""
		end

		local out = parts[1]
		for i = 2, #parts do
			out = out .. string.rep(" ", gap_after(i - 1)) .. parts[i]
		end
		return out
	end

	compute_widths(columns, rows, math.max(width - (margin * 2), 1), gap_after, tree, fill)

	local lines = {}
	local line_map = {}
	local spans = {}

	local col_start = margin
	if show_header then
		local header_parts = {}
		for i, c in ipairs(columns) do
			local label = truncate(c.name or "", c._computed)
			local header_align = c.header_align
			if header_align == nil and c.align_title == true then
				header_align = c.align
			end
			local padded = pad_aligned(label, c._computed, header_align)
			table.insert(header_parts, padded)

			table.insert(spans, {
				line = 0,
				start_col = col_start,
				end_col = col_start + #padded,
				hl_group = c.header_hl or "AtlasColumnHeader",
			})

			col_start = col_start + #padded + gap_after(i)
		end
		table.insert(lines, string.rep(" ", margin) .. join_parts(header_parts))
		table.insert(lines, "")
	end

	for _, row in ipairs(rows) do
		if row._tv2_separator then
			local sep = tostring(row._tv2_separator_char or "─")
			local content_width = math.max(width - (margin * 2), 1)
			local sep_line = string.rep(" ", margin) .. string.rep(sep, content_width)
			table.insert(lines, "")
			table.insert(lines, sep_line)
			table.insert(spans, {
				line = #lines - 1,
				start_col = margin,
				end_col = #sep_line,
				hl_group = "AtlasTextMuted",
			})
			line_map[#lines] = row
			table.insert(lines, "")
		else
			local line_parts = {}
			col_start = margin
			for i, c in ipairs(columns) do
				local cell = truncate(cell_text(row, c, tree), c._computed, c.truncate_from == "start")
				local padded = pad_aligned(cell, c._computed, c.align)
				table.insert(line_parts, padded)

				local cell_spans = nil
				if type(cell_hl) == "function" then
					cell_spans = cell_hl(row, c, {
						text = cell,
						padded = padded,
						width = c._computed,
					})
				end

				if type(cell_spans) == "string" then
					table.insert(spans, {
						line = #lines,
						start_col = col_start,
						end_col = col_start + #padded,
						hl_group = cell_spans,
					})
				elseif type(cell_spans) == "table" then
					for _, span in ipairs(cell_spans) do
						if type(span) == "table" and type(span.hl_group) == "string" then
							local rel_start = math.max(0, tonumber(span.start_col) or 0)
							local rel_end = math.min(#padded, tonumber(span.end_col) or #padded)
							if rel_end > rel_start then
								table.insert(spans, {
									line = #lines,
									start_col = col_start + rel_start,
									end_col = col_start + rel_end,
									hl_group = span.hl_group,
								})
							end
						end
					end
				elseif c.hl then
					table.insert(spans, {
						line = #lines,
						start_col = col_start,
						end_col = col_start + #padded,
						hl_group = c.hl,
					})
				end

				col_start = col_start + #padded + gap_after(i)
			end
			table.insert(lines, string.rep(" ", margin) .. join_parts(line_parts))
			line_map[#lines] = row._item or row

			if row.separator == true then
				local sep_char = row.separator_char or "─"
				local sep_hl = row.separator_hl or "AtlasTextMuted"
				local sep_line = string.rep(" ", margin) .. string.rep(sep_char, math.max(width - (margin * 2), 1))
				table.insert(lines, sep_line)
				table.insert(spans, {
					line = #lines - 1,
					start_col = margin,
					end_col = margin + #sep_line - margin,
					hl_group = sep_hl,
				})
			end
		end
	end

	return lines, line_map, spans
end

return M
