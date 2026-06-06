local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local ui_utils = require("atlas.ui.utils")

---@param queries { key?: string, label?: string, items?: table }|nil
---@param default_key string
---@param default_label string
---@return table|nil
function M.build_view(queries, default_key, default_label)
	if type(queries) ~= "table" or type(queries.items) ~= "table" then
		return nil
	end
	if next(queries.items) == nil then
		return nil
	end
	return {
		name = tostring(queries.label or default_label),
		key = tostring(queries.key or default_key),
		layout = "plain",
		_kind = "bookmarks",
		_bookmarks = queries.items,
	}
end

---@param items table<string, any>
---@return { name: string, value: any }[]
local function sorted_items(items)
	local out = {}
	for name, value in pairs(items or {}) do
		table.insert(out, { name = tostring(name), value = value })
	end
	table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
	return out
end

M.sorted_items = sorted_items

---@param value any
---@return string
local function preview_text(value)
	if type(value) == "string" then
		return value
	end
	if type(value) ~= "table" then
		return ""
	end

	local keys = {}
	for k in pairs(value) do
		if type(value[k]) ~= "table" then
			table.insert(keys, tostring(k))
		end
	end
	table.sort(keys)

	local parts = {}
	for _, k in ipairs(keys) do
		local v = value[k]
		if v ~= nil and v ~= "" then
			table.insert(parts, k .. ":" .. tostring(v))
		end
	end
	for _, v in pairs(value) do
		if type(v) == "table" then
			for ek, ev in pairs(v) do
				table.insert(parts, tostring(ek) .. "=" .. tostring(ev))
			end
		end
	end
	return table.concat(parts, " ")
end

---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param items_table table<string, any>
---@param width integer
function M.render(lines, spans, line_map, items_table, width)
	local items = sorted_items(items_table)
	local bookmark = icons.general("star") or "*"
	local arrow = icons.general("arrow_right") or "▸"

	local header = string.format(" %s  Bookmarks", bookmark)
	table.insert(lines, header)
	local hl_end = 1 + #bookmark
	table.insert(spans, { line = #lines - 1, start_col = 1, end_col = hl_end, hl_group = "AtlasLogInfo" })
	table.insert(spans, { line = #lines - 1, start_col = hl_end, end_col = #header, hl_group = "AtlasTextMuted" })

	if #items == 0 then
		local msg = " No bookmarks configured."
		table.insert(lines, msg)
		table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #msg, hl_group = "AtlasTextMuted" })
		return
	end

	local left_indent = 1
	local gap = 4
	local arrow_w = ui_utils.text_width(arrow)
	local name_w = 0
	for _, item in ipairs(items) do
		local w = ui_utils.text_width(item.name)
		if w > name_w then name_w = w end
	end
	local prefix_w = left_indent + arrow_w + 2 + name_w + gap
	local preview_w = math.max(width - prefix_w - left_indent, 10)

	for _, item in ipairs(items) do
		local item_w = ui_utils.text_width(item.name)
		local name_pad = string.rep(" ", math.max(name_w - item_w, 0))
		local preview = preview_text(item.value)
		preview = utils.truncate(preview, preview_w, false)

		local row = string.format(" %s  %s%s%s%s",
			arrow,
			item.name,
			name_pad,
			string.rep(" ", gap),
			preview
		)
		table.insert(lines, row)

		local lnum = #lines - 1
		local arrow_start = left_indent
		local arrow_end = arrow_start + #arrow
		table.insert(spans, { line = lnum, start_col = arrow_start, end_col = arrow_end, hl_group = "AtlasTextMuted" })

		if preview ~= "" then
			local preview_start = prefix_w
			table.insert(spans, { line = lnum, start_col = preview_start, end_col = #row, hl_group = "AtlasTextMuted" })
		end

		line_map[#lines] = { kind = "bookmark", name = item.name, value = item.value }
	end
end

return M
