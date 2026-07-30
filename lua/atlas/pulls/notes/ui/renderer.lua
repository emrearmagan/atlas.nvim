local box = require("atlas.ui.components.box")
local icons = require("atlas.ui.shared.icons")
local notes = require("atlas.pulls.notes")
local table_tree = require("atlas.ui.components.table_tree")
local threadsv2 = require("atlas.ui.components.threadsv2")
local utils = require("atlas.ui.shared.utils")

local M = {}

---@class AtlasNotesUIItem
---@field kind "target"|"note"|"spacer"
---@field target AtlasNoteTarget
---@field note AtlasNote|nil

---@class AtlasNotesUIRenderOptions
---@field actions boolean|nil
---@field boxed boolean|nil
---@field padding_x integer|nil
---@field outdated table<string, boolean>|nil
---@field collapse_outdated boolean|nil

---@class AtlasNotesUIManagerRenderOptions
---@field documents AtlasNotesUIManagerDocument[]
---@field width integer
---@field target_filter AtlasNoteTarget|nil

---@class AtlasNotesUIManagerDocument
---@field target AtlasNoteTarget
---@field notes AtlasNote[]

---@class AtlasNotesUISpan
---@field line integer
---@field start_col integer
---@field end_col integer
---@field hl_group string

---@param value string|nil
---@return string
local function trim(value)
	return vim.trim(tostring(value or ""))
end

---@param value string|nil
---@return string
local function type_label(value)
	return tostring(value or "note"):upper()
end

---@param note AtlasNote
---@return string
function M.note_label(note)
	local label = trim(note.body:match("([^\r\n]+)"))
	return label ~= "" and label or "(empty note)"
end

---@param note_type AtlasNoteType
---@return string icon, string highlight
function M.type_style(note_type)
	if note_type == "issue" then
		return icons.general("error")
	end
	if note_type == "suggestion" then
		return icons.general("warning")
	end
	if note_type == "praise" then
		return icons.general("success")
	end
	return icons.general("info")
end

---@param note_type AtlasNoteType
---@param file_path string
---@param line integer
---@return string
function M.note_title(note_type, file_path, line)
	return string.format("Note [%s] %s:%d", type_label(note_type), file_path, line)
end

---@param note AtlasNote
---@param target AtlasNoteTarget|nil
---@return string[]
function M.details_lines(note, target)
	local label = target and notes.target_label(target) or "Unknown pull request"
	local lines = {
		"# " .. M.note_label(note),
		"",
		string.format("**%s** · `%s:%d` · `%s`", type_label(note.type), note.file_path, note.line, label),
	}
	if target then
		table.insert(lines, "")
		table.insert(lines, "Target: `" .. target.ref .. "`")
		if target.repo_path then
			table.insert(lines, "Checkout: `" .. target.repo_path .. "`")
		end
	end
	table.insert(lines, "")
	vim.list_extend(lines, vim.split(note.body, "\n", { plain = true }))
	table.insert(lines, "")
	table.insert(lines, "Created: `" .. note.created_at .. "`")
	if note.updated_at then
		table.insert(lines, "Updated: `" .. note.updated_at .. "`")
	end
	return lines
end

---@param note AtlasNote
---@param width integer
---@param padding_x integer
---@param opts AtlasNotesUIRenderOptions
---@return AtlasThreadV2Item
local function note_item(note, width, padding_x, opts)
	local timestamp = utils.relative_time(note.updated_at or note.created_at)
	local author = string.format("Note [%s]", type_label(note.type))
	local outdated = opts.outdated and opts.outdated[note.id]
	local location = string.format("%s:%d", note.file_path, note.line)
	if outdated then
		location = "outdated · " .. location
	end
	local right_width = timestamp ~= "" and vim.api.nvim_strwidth(timestamp) + 2 or 0
	local available = width - padding_x - vim.api.nvim_strwidth(author) - right_width - 4
	if vim.api.nvim_strwidth(location) > available then
		location = utils.truncate(location, math.max(1, available), true)
	end
	local footer_items = {}
	if opts.actions then
		footer_items = { "e edit", "d delete" }
	end
	local content = utils.strip_markup(note.body)
	if outdated and opts.collapse_outdated then
		content = nil
	end
	return {
		icon = "",
		author = author,
		additional = location,
		right_text = timestamp,
		content = content,
		children = {},
		footer_items = footer_items,
		line_map = { entity_kind = "note", note = note },
		meta = {
			type_hl = select(2, M.type_style(note.type)),
		},
	}
end

---@param items AtlasNote[]
---@param width integer
---@param opts AtlasNotesUIRenderOptions|nil
---@return string[], AtlasNotesUISpan[], table<integer, table>
function M.render_cards(items, width, opts)
	opts = opts or {}
	width = math.max(6, width)
	local boxed = opts.boxed ~= false
	local padding_x = opts.padding_x or (boxed and 0 or 1)
	local content_width = boxed and math.max(1, width - 3) or width
	local rendered_items = {}
	for _, note in ipairs(items) do
		table.insert(rendered_items, note_item(note, content_width, padding_x, opts))
	end
	local lines, spans, line_map = threadsv2.render(rendered_items, content_width, {
		padding_x = padding_x,
		separator = "─",
		author_hl = function(item)
			return item.meta.type_hl
		end,
		additional_hl = function()
			return "AtlasTextMuted"
		end,
		right_text_hl = function()
			return "AtlasTextMuted"
		end,
	})
	if not boxed then
		return lines, spans, line_map
	end
	local rendered = box.render({ { lines = lines, spans = spans, line_map = line_map } }, {
		width = width,
		padding_x = 0,
	})
	return rendered.lines, rendered.highlights, rendered.line_map
end

---@param row table
---@param column table
---@return string|nil
local function cell_highlight(row, column)
	local item = row._item
	if item and item.kind == "target" and column.key == "note" then
		return "AtlasLogInfo"
	end
	if column.key == "type" then
		return select(2, M.type_style(tostring(row.type or "note"):lower()))
	end
	if column.key == "location" or column.key == "updated" then
		return "AtlasTextMuted"
	end
	return nil
end

---@param opts AtlasNotesUIManagerRenderOptions
---@return string[], table<integer, AtlasNotesUIItem>, AtlasNotesUISpan[]
function M.render_manager(opts)
	local rows = {}
	for index, document in ipairs(opts.documents) do
		local children = {}
		for _, note in ipairs(document.notes) do
			table.insert(children, {
				note = M.note_label(note),
				location = string.format("%s:%d", note.file_path, note.line),
				type = type_label(note.type),
				updated = tostring(note.updated_at or note.created_at):sub(1, 10),
				_item = { kind = "note", target = document.target, note = note },
			})
		end
		table.insert(rows, {
			note = string.format(
				"%s · %s (%d)",
				notes.target_label(document.target),
				document.target.host,
				#document.notes
			),
			children = children,
			_item = { kind = "target", target = document.target, note = nil },
		})
		if index < #opts.documents then
			table.insert(rows, {
				_item = { kind = "spacer", target = document.target, note = nil },
			})
		end
	end

	if #rows == 0 then
		local message = "No notes found"
		if opts.target_filter then
			message = string.format("%s for %s", message, notes.target_label(opts.target_filter))
		end
		message = "  " .. message .. "."
		return { "", message }, {}, {
			{ line = 1, start_col = 0, end_col = #message, hl_group = "AtlasTextMuted" },
		}
	end

	local columns = {
		{ key = "note", name = "Notes", min_width = 24 },
		{ key = "location", name = "File", min_width = 18 },
		{ key = "type", name = "Type", min_width = 10, can_grow = false },
		{ key = "updated", name = "Updated", width = 10 },
	}
	return table_tree.render({
		width = math.max(opts.width, 1),
		margin = 1,
		columns = columns,
		rows = rows,
		tree = {
			column_key = "note",
			children_key = "children",
			default_expanded = true,
			indent = "",
			leaf_prefix = "  ",
			show_indicator = false,
		},
		cell_hl = cell_highlight,
	})
end

return M
