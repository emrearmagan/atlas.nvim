local table_tree = require("atlas.ui.components.table_tree")
local utils = require("atlas.ui.shared.utils")

local M = {}

---@param tag AtlasRepositoryTag
---@return AtlasPickerPreview
function M.preview(tag)
	local lines = { "Tag: " .. tag.name, "Commit: " .. tag.hash }
	if tag.author and tag.author ~= "" then
		table.insert(lines, "Author: " .. tag.author)
	end

	if tag.tag_date and tag.tag_date ~= "" then
		table.insert(lines, "Tag date: " .. tag.tag_date)
	end

	local annotation = tag.description and tag.description ~= "" and tag.description or nil
	local message = annotation or tag.message
	if message and message ~= "" then
		table.insert(lines, "")
		table.insert(lines, annotation and "Tag annotation:" or "Commit message:")
		vim.list_extend(lines, utils.sanitize_lines(message))
	end

	return { title = tag.name, lines = lines }
end

---@param tag AtlasRepositoryTag
---@param width integer
---@return string[]
local function detail_lines(tag, width)
	local details = {}
	for index, line in ipairs(M.preview(tag).lines) do
		if index > 1 then
			for _, wrapped in ipairs(utils.wrap_line(line, math.max(1, width - 5))) do
				table.insert(details, "  │ " .. wrapped)
			end
		end
	end

	return details
end

---@param state RepositoryTags
---@param width integer
---@return string[], table[], table<integer, RepositoryTagSelection>
function M.render(state, width)
	local rows = {}
	local tags = state.tags
	---@cast tags AtlasRepositoryTag[]
	for _, tag in ipairs(tags) do
		local message = tag.description and tag.description ~= "" and tag.description or tag.message or ""
		local date = utils.format_date(tag.tag_date)
		table.insert(rows, {
			name = (state.expanded == tag.name and "▾ " or "▸ ") .. tag.name,
			message = message:match("^[^\r\n]*"),
			hash = tag.hash:sub(1, 8),
			date = date ~= "" and date or "-",
			_item = { tag = tag },
		})
	end

	local lines, line_map, spans = table_tree.render({
		columns = {
			{ key = "name", name = "Tag", can_grow = false, hl = "Normal" },
			{ key = "message", name = "Annotation or commit", hl = "AtlasTextMuted" },
			{ key = "hash", name = "Commit", can_grow = false, hl = "AtlasTextMuted" },
			{ key = "date", name = "Date", align = "right", header_align = "right", hl = "AtlasTextMuted" },
		},
		rows = rows,
		width = width - 1,
		margin = 0,
		show_header = false,
	})

	local row
	for line, selection in pairs(line_map) do
		if selection.tag.name == state.expanded then
			row = line
		end
	end

	if not row then
		return lines, spans, line_map
	end

	local tag = line_map[row].tag
	local details = detail_lines(tag, width)
	for _, span in ipairs(spans) do
		if span.line >= row then
			span.line = span.line + #details
		end
	end

	for line = #lines, row + 1, -1 do
		line_map[line + #details] = line_map[line]
	end

	for index, text in ipairs(details) do
		table.insert(lines, row + index, text)
		line_map[row + index] = { tag = tag, detail = index }
		table.insert(spans, { line = row + index - 1, start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" })
	end

	return lines, spans, line_map
end

return M
