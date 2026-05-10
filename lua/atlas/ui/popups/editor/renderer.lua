local M = {}

local table_tree = require("atlas.ui.components.table_tree")

local NS = vim.api.nvim_create_namespace("atlas.editor.meta")

local function valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function cell_value(cell)
	if type(cell) == "table" then
		return tostring(cell.text or "")
	end
	return tostring(cell or "")
end

local function default_hl(cell, index)
	if type(cell) == "table" and cell.hl then
		return cell.hl
	end
	if index % 2 == 1 then
		return "AtlasTextMuted"
	end
	return nil
end

---@param rows EditorPopupMetaRow[]
---@return table[]
---@return table[]
local function table_rows(rows)
	local columns = {}
	local items = {}
	local column_count = 0

	for _, row in ipairs(rows or {}) do
		column_count = math.max(column_count, #row)
	end

	for i = 1, column_count do
		table.insert(columns, {
			key = i,
			name = "",
			can_grow = i % 2 == 0,
			grow_last = i == column_count,
		})
	end

	for _, row in ipairs(rows or {}) do
		local item = { _hls = {}, _spans = {} }
		for i, cell in ipairs(row) do
			item[i] = cell_value(cell)
			item._hls[i] = default_hl(cell, i)
			if type(cell) == "table" then
				item._spans[i] = cell.spans
			end
		end
		table.insert(items, item)
	end

	return columns, items
end

---@param state { layout: EditorPopupLayout, content_width: integer }
---@param rows EditorPopupMetaRow[]
function M.render_meta(state, rows)
	local buf = state.layout.meta_buf
	if not valid_buf(buf) then
		return
	end

	local columns, items = table_rows(rows or {})

	local lines, _, spans = table_tree.render({
		columns = columns,
		rows = items,
		width = state.content_width,
		margin = 0,
		show_header = false,
		column_gap = 2,
		fill = true,
		cell_hl = function(row, col)
			local text = row[col.key] or ""
			local spans = row._spans and row._spans[col.key]
			if spans then
				return spans
			end

			local hl = row._hls and row._hls[col.key]
			if text ~= "" and hl then
				return {
					{ start_col = 0, end_col = #text, hl_group = hl },
				}
			end

			return nil
		end,
	})

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

	vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
	for _, span in ipairs(spans or {}) do
		pcall(vim.api.nvim_buf_set_extmark, buf, NS, span.line, span.start_col, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
end

return M
