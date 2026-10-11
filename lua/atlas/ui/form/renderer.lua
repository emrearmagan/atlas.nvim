local M = {}

local table_tree = require("atlas.ui.components.table_tree")
local utils = require("atlas.ui.shared.utils")

local NS = vim.api.nvim_create_namespace("atlas.editor.meta")
local LABELS_NS = vim.api.nvim_create_namespace("atlas.editor.labels")

---@class AtlasFormMetaField
---@field key string
---@field value string
---@field loading boolean|nil
---@field hl string|nil
---@field spans { start_col: integer, end_col: integer, hl_group: string }[]|nil

---@alias AtlasFormMetaRow AtlasFormMetaField[]

---@param rows AtlasFormMetaRow[]
---@param loading_text string
---@return table[]
---@return table[]
---@return integer
local function table_rows(rows, loading_text)
	local columns = {}
	local items = {}
	local column_count = 0
	local key_width = 0

	for _, row in ipairs(rows) do
		if row[1] then
			local key = row[1].key:gsub("%c", " ")
			key_width = math.max(key_width, vim.fn.strdisplaywidth(key))
		end
		if #row ~= 1 then
			column_count = math.max(column_count, #row * 2)
			local item = { _fields = row }
			for i, field in ipairs(row) do
				item[i * 2 - 1] = field.key
				item[i * 2] = field.loading and loading_text or field.value
			end
			table.insert(items, item)
		end
	end

	for i = 1, column_count do
		table.insert(columns, {
			key = i,
			name = "",
			width = i == 1 and key_width or nil,
		})
	end

	return columns, items, key_width
end

local function render_field(field, width, key_width, loading_text)
	local value = (field.loading and loading_text or field.value):gsub("%c", " ")
	local highlights = {}
	if not field.loading and field.spans then
		for _, span in ipairs(field.spans) do
			table.insert(highlights, {
				line = 0,
				start_col = span.start_col,
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end
	elseif field.loading or field.hl then
		highlights = {
			{ line = 0, start_col = 0, end_col = #value, hl_group = field.loading and "AtlasTextMuted" or field.hl },
		}
	end

	local content =
		utils.wrap_content({ lines = { value }, highlights = highlights }, math.max(1, width - key_width - 2), "")
	local key = field.key:gsub("%c", " ")
	local prefix = key .. string.rep(" ", key_width - vim.fn.strdisplaywidth(key) + 2)
	local indent = string.rep(" ", key_width + 2)
	for i, line in ipairs(content.lines) do
		content.lines[i] = (i == 1 and prefix or indent) .. line
	end
	for _, span in ipairs(content.highlights) do
		local offset = span.line == 0 and #prefix or #indent
		span.start_col = span.start_col + offset
		span.end_col = span.end_col + offset
	end
	table.insert(content.highlights, { line = 0, start_col = 0, end_col = #key, hl_group = "AtlasTextMuted" })
	return content
end

---@param form AtlasForm
function M.render_meta(form)
	local buf = form.meta_buf
	local win = form.meta_win
	if
		form.closed
		or not utils.buffer.valid(buf)
		or not utils.window.valid(win)
		or not utils.buffer.valid(form.editor_buf)
		or not utils.window.valid(form.editor_win)
	then
		return
	end
	local width = vim.api.nvim_win_get_width(win)
	local loading_text = form.meta_spinner:text()
	local columns, items, key_width = table_rows(form.meta_rows, loading_text)

	local lines, _, spans = table_tree.render({
		columns = columns,
		rows = items,
		width = width,
		margin = 0,
		show_header = false,
		column_gap = 2,
		fill = false,
		cell_hl = function(row, col)
			if col.key % 2 == 0 then
				local field = row._fields[col.key / 2]
				if field and field.loading then
					return "AtlasTextMuted"
				end
				return field and (field.spans or field.hl)
			end
			return "AtlasTextMuted"
		end,
	})

	local meta_lines, meta_spans = {}, {}
	local table_offsets = {}
	local table_index = 1
	for _, row in ipairs(form.meta_rows) do
		if #row == 1 then
			utils.append_block(meta_lines, meta_spans, render_field(row[1], width, key_width, loading_text))
		else
			table_offsets[table_index] = #meta_lines
			table.insert(meta_lines, lines[table_index])
			table_index = table_index + 1
		end
	end
	for _, span in ipairs(spans) do
		span.line = table_offsets[span.line + 1]
		table.insert(meta_spans, span)
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, meta_lines)
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
	for _, span in ipairs(meta_spans) do
		vim.api.nvim_buf_set_extmark(buf, NS, span.line, span.start_col, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
	local height = vim.api.nvim_win_get_height(win)
	local available = height + vim.api.nvim_win_get_height(form.editor_win)
	local target = math.max(2, math.min(#meta_lines + 1, math.floor(available / 3)))
	if target ~= height then
		vim.api.nvim_win_set_height(win, target)
	end

	vim.api.nvim_buf_clear_namespace(form.editor_buf, LABELS_NS, 0, -1)
	vim.api.nvim_buf_set_extmark(form.editor_buf, LABELS_NS, 0, 0, {
		virt_text = { { "Title: ", "WinBar" } },
		virt_text_pos = "inline",
		right_gravity = false,
	})
	vim.api.nvim_buf_set_extmark(form.editor_buf, LABELS_NS, 0, 0, {
		virt_lines = {
			{ { "", "Normal" } },
			{ { "Description", "WinBar" } },
		},
		virt_lines_leftcol = true,
		right_gravity = false,
	})
end

return M
