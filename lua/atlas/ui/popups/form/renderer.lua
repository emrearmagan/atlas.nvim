local M = {}

local footer = require("atlas.ui.components.footer")
local table_tree = require("atlas.ui.components.table_tree")
local text_utils = require("atlas.ui.shared.utils")
local ui_utils = require("atlas.ui.utils")

local NS = vim.api.nvim_create_namespace("atlas.editor.meta")
local FOOTER_NS = vim.api.nvim_create_namespace("atlas.editor.footer")

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

---@param rows AtlasFormMetaRow[]
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

---@param state { layout: AtlasFormLayout, content_width: integer }
---@param rows AtlasFormMetaRow[]
function M.render_meta(state, rows)
	local layout = state.layout
	local buf = layout.editor_buf
	if not valid_buf(buf) then
		return
	end
	local win = layout.editor_win
	if win and vim.api.nvim_win_is_valid(win) then
		state.content_width = vim.api.nvim_win_get_width(win)
	end

	local columns, items = table_rows(rows or {})

	local lines, _, spans = table_tree.render({
		columns = columns,
		rows = items,
		width = state.content_width,
		margin = 0,
		show_header = false,
		column_gap = 2,
		fill = false,
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

	vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

	local top_lines = { "Details" }
	vim.list_extend(top_lines, lines)
	local separator_line = #top_lines + 1
	table.insert(top_lines, string.rep("─", math.max(1, state.content_width)))
	table.insert(top_lines, layout.title_label or "Title")

	local top_spans = {
		{ line = 0, start_col = 0, end_col = #top_lines[1], hl_group = "AtlasLogInfo" },
		{
			line = separator_line - 1,
			start_col = 0,
			end_col = #top_lines[separator_line],
			hl_group = "AtlasBorder",
		},
		{
			line = #top_lines - 1,
			start_col = 0,
			end_col = #top_lines[#top_lines],
			hl_group = "AtlasLogInfo",
		},
	}
	for _, span in ipairs(spans or {}) do
		table.insert(top_spans, {
			line = span.line + 1,
			start_col = span.start_col,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end

	vim.api.nvim_buf_set_extmark(buf, NS, 0, 0, {
		virt_lines = text_utils.virtual_lines(top_lines, top_spans),
		virt_lines_above = true,
		virt_lines_leftcol = true,
		right_gravity = false,
	})
	vim.api.nvim_buf_set_extmark(buf, NS, 0, 0, {
		virt_lines = { { { layout.body_label or "Description", "AtlasLogInfo" } } },
		virt_lines_leftcol = true,
		right_gravity = false,
	})

	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_call(win, function()
			-- Virtual lines above line 1 need topfill to remain visible.
			if vim.fn.winsaveview().topline == 1 then
				vim.fn.winrestview({ topfill = #top_lines })
			end
		end)
	end
end

---@param state { layout: AtlasFormLayout }
---@param lines string[]
function M.render_context(state, lines)
	local buf = state.layout.context_buf
	if not valid_buf(buf) then
		return
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { "" })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---@param opts AtlasFormOpenOpts
---@return table[]
local function footer_segments(opts)
	local items = { { key = "<C-s>", desc = "submit" } }
	for _, keymap in ipairs(opts.keymaps or {}) do
		table.insert(items, { key = keymap.key, desc = keymap.desc })
	end
	table.insert(items, { key = "q", desc = "close" })

	local segments = {}
	for _, item in ipairs(items) do
		table.insert(segments, { text = item.key, hl_group = "AtlasTextWarning" })
		table.insert(segments, { text = item.desc, hl_group = "AtlasFooterText" })
	end
	return segments
end

---@param layout AtlasFormLayout
---@param opts AtlasFormOpenOpts
function M.render_footer(layout, opts)
	local buf = layout.footer_buf
	local win = layout.footer_win
	if not valid_buf(buf) or not win or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local block = footer.render({
		width = vim.api.nvim_win_get_width(win),
		segments = footer_segments(opts),
	})
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, block.lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_buf_clear_namespace(buf, FOOTER_NS, 0, -1)
	for _, span in ipairs(block.highlights) do
		local clamped = ui_utils.clamp_span(block.lines, span)
		if clamped then
			vim.api.nvim_buf_set_extmark(buf, FOOTER_NS, clamped.line, clamped.start_col, {
				end_col = clamped.end_col,
				hl_group = clamped.hl_group,
			})
		end
	end
end

return M
