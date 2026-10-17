local markdown = require("atlas.formats.markdown")
local icons = require("atlas.ui.shared.icons")
local notes = require("atlas.pulls.notes")
local threads = require("atlas.ui.components.threads")
local utils = require("atlas.ui.shared.utils")

local M = {}
local note_icon, note_icon_hl = icons.get("pin")
local progress_icon = icons.get("progress")
local resolved_icon, resolved_icon_hl = icons.get("success")

---@class AtlasNotesUIItem
---@field target AtlasStorageTarget|nil
---@field note AtlasNote|nil
---@field tree_key string|nil

---@class AtlasNotesUIActionKeys
---@field edit? string
---@field delete? string
---@field toggle_resolved? string

---@class AtlasNotesUIRenderOptions
---@field action_keys AtlasNotesUIActionKeys|nil
---@field expanded boolean|nil
---@field padding_x integer|nil
---@field outdated table<string, boolean>|nil
---@field location (fun(note: AtlasNote): string)|nil

---@class AtlasNotesUIListItem
---@field target AtlasStorageTarget
---@field note AtlasNote
---@field expanded boolean

---@class AtlasNotesUIListRenderOptions
---@field padding_x integer|nil
---@field action_keys AtlasNotesUIActionKeys|nil

---@class AtlasNotesUIManagerRenderOptions
---@field documents AtlasNotesUIManagerDocument[]
---@field width integer
---@field filter_label string|nil
---@field expanded table<string, boolean>
---@field action_keys AtlasNotesUIActionKeys|nil

---@class AtlasNotesUIManagerDocument
---@field target AtlasStorageTarget
---@field notes AtlasNote[]

---@param value AtlasNoteType
---@return string
local function type_label(value)
	return value:upper()
end

---@param target AtlasStorageTarget
---@param note AtlasNote
---@return string
function M.note_key(target, note)
	return "note:" .. target.ref .. ":" .. note.id
end

---@param note_type AtlasNoteType
---@return string
local function type_highlight(note_type)
	if note_type == "issue" then
		return "AtlasLogError"
	end
	if note_type == "suggestion" then
		return "AtlasLogWarn"
	end
	if note_type == "praise" then
		return "AtlasTextPositive"
	end
	return "AtlasLogInfo"
end

---@param value { start_line: integer, end_line: integer }
---@return string
function M.line_range(value)
	if value.start_line == value.end_line then
		return tostring(value.start_line)
	end
	return string.format("%d-%d", value.start_line, value.end_line)
end

---@param note_type AtlasNoteType
---@param value { file_path: string, start_line: integer, end_line: integer }
---@return string
function M.note_title(note_type, value)
	return string.format("Note [%s] %s:%s", type_label(note_type), value.file_path, M.line_range(value))
end

---@param note AtlasNote
---@param target AtlasStorageTarget
---@param width integer|nil
---@return string[], AtlasUIHighlight[]
function M.render_details(note, target, width)
	local label = notes.target_label(target)
	local note_type = type_label(note.type)
	local location = note.file_path .. ":" .. M.line_range(note)
	local lines = { string.format("%s  %s  %s", note_type, location, label), "", "Target: " .. target.ref }
	local spans = {
		{ line = 0, start_col = 0, end_col = #note_type, hl_group = type_highlight(note.type) },
		{ line = 0, start_col = #note_type, end_col = #lines[1], hl_group = "AtlasTextMuted" },
		{ line = 2, start_col = 0, end_col = 7, hl_group = "AtlasTextMuted" },
	}
	if note.resolved then
		local start_col = #lines[1] + 2
		lines[1] = lines[1] .. "  " .. resolved_icon .. " resolved"
		table.insert(spans, {
			line = 0,
			start_col = start_col,
			end_col = #lines[1],
			hl_group = resolved_icon_hl,
		})
	end
	table.insert(lines, "")
	utils.append_block(lines, spans, markdown.parse(note.body, { width = width }))
	table.insert(lines, "")
	table.insert(lines, "Created: " .. note.created_at)
	table.insert(spans, { line = #lines - 1, start_col = 0, end_col = 8, hl_group = "AtlasTextMuted" })
	if note.updated_at then
		table.insert(lines, "Updated: " .. note.updated_at)
		table.insert(spans, { line = #lines - 1, start_col = 0, end_col = 8, hl_group = "AtlasTextMuted" })
	end
	return lines, spans
end

---@param note AtlasNote
---@param action_keys AtlasNotesUIActionKeys|nil
---@return AtlasThreadFooterItem[]
local function note_footer(note, action_keys)
	local footer_items = {}
	for _, action in ipairs({ "edit", "delete" }) do
		local key = action_keys and action_keys[action]
		if key then
			table.insert(footer_items, {
				text = string.format("%s %s", key, action),
				hl_group = "AtlasTextMuted",
			})
		end
	end
	local toggle_key = action_keys and action_keys.toggle_resolved
	if toggle_key then
		table.insert(footer_items, {
			text = string.format("%s %s", toggle_key, note.resolved and "reopen" or "resolve"),
			hl_group = "AtlasTextMuted",
		})
	end
	return footer_items
end

---@param note AtlasNote
---@param outdated boolean|nil
---@return [string, string][]
function M.status_marker(note, outdated)
	local chunks = {}
	if note.resolved then
		chunks[#chunks + 1] = { resolved_icon, resolved_icon_hl }
	end
	if outdated then
		if #chunks > 0 then
			chunks[#chunks + 1] = { " ", "AtlasTextMuted" }
		end
		chunks[#chunks + 1] = { progress_icon, "AtlasTextWarning" }
	end
	return chunks
end

---@param note AtlasNote
---@param opts AtlasNotesUIRenderOptions
---@return AtlasThreadItem
local function card_item(note, opts)
	local timestamp = utils.relative_time(note.updated_at or note.created_at)
	if opts.location then
		timestamp = vim.trim(timestamp .. "  " .. opts.location(note))
	end
	local outdated = opts.outdated and opts.outdated[note.id]
	local collapsed = opts.expanded == false and (note.resolved or outdated)

	return {
		icon = note_icon,
		icon_hl = note_icon_hl,
		author = string.format("Note [%s]", type_label(note.type)),
		author_hl = type_highlight(note.type),
		additional = { { timestamp, "AtlasTextMuted" } },
		right_text = M.status_marker(note, outdated),
		content = not collapsed and note.body or nil,
		markdown = true,
		children = {},
		footer_items = collapsed and {} or note_footer(note, opts.action_keys),
		line_map = { note = note },
	}
end

---@param items AtlasNote[]
---@param width integer
---@param opts AtlasNotesUIRenderOptions|nil
---@return string[], AtlasUIHighlight[], table<integer, table>
function M.render_cards(items, width, opts)
	opts = opts or {}
	local rendered_items = {}
	for _, note in ipairs(items) do
		table.insert(rendered_items, card_item(note, opts))
	end
	return threads.render(rendered_items, width, {
		padding_x = opts.padding_x or 0,
	})
end

---@param item AtlasNotesUIListItem
---@param opts AtlasNotesUIListRenderOptions
---@return AtlasThreadItem
local function list_item(item, opts)
	local note = item.note
	local path = note.file_path:match("([^/\\]+)$") or note.file_path
	local metadata = { { path .. ":" .. M.line_range(note), "Normal" } }
	local timestamp = utils.relative_time(note.updated_at or note.created_at)
	if timestamp ~= "" then
		metadata[#metadata + 1] = { "  " .. timestamp, "AtlasTextMuted" }
	end
	if note.resolved then
		metadata[#metadata + 1] = { "  ", "AtlasTextMuted" }
		metadata[#metadata + 1] = { resolved_icon .. " resolved", resolved_icon_hl }
	end

	local expander, expander_hl = icons.get(item.expanded and "fold_open" or "fold_closed")
	return {
		icon = expander,
		icon_hl = expander_hl,
		author = type_label(note.type),
		author_hl = type_highlight(note.type),
		additional = metadata,
		content = item.expanded and note.body or nil,
		markdown = true,
		children = {},
		footer_items = item.expanded and note_footer(note, opts.action_keys) or {},
		line_map = {
			target = item.target,
			note = note,
			tree_key = M.note_key(item.target, note),
		},
	}
end

---@param items AtlasNotesUIListItem[]
---@param width integer
---@param opts AtlasNotesUIListRenderOptions|nil
---@return string[], AtlasUIHighlight[], table<integer, AtlasNotesUIItem>
function M.render_list(items, width, opts)
	opts = opts or {}
	width = math.max(width, 6)
	local padding_x = opts.padding_x or 0
	local lines, spans, line_map = {}, {}, {}
	for index, item in ipairs(items) do
		local offset = #lines
		local item_lines, item_spans, item_map = threads.render({ list_item(item, opts) }, width, {
			padding_x = padding_x,
		})
		utils.append_block(lines, spans, { lines = item_lines, highlights = item_spans })
		for line, entry in pairs(item_map) do
			line_map[offset + line] = entry
		end
		if item.expanded and index < #items then
			table.insert(lines, "")
		end
	end
	return lines, spans, line_map
end

---@param opts AtlasNotesUIManagerRenderOptions
---@return string[], AtlasUIHighlight[], table<integer, AtlasNotesUIItem>
function M.render_manager(opts)
	local lines, spans, line_map = {}, {}, {}
	for _, document in ipairs(opts.documents) do
		local items = {}
		for _, note in ipairs(document.notes) do
			local key = M.note_key(document.target, note)
			table.insert(items, {
				target = document.target,
				note = note,
				expanded = opts.expanded[key] == true,
			})
		end
		if #items > 0 then
			if #lines > 0 then
				table.insert(lines, "")
			end
			local target = notes.target_label(document.target)
			local key = "target:" .. document.target.ref
			local expanded = opts.expanded[key] == true
			local expander = icons.get(expanded and "fold_open" or "fold_closed")
			local count = string.format("  %d %s", #items, #items == 1 and "note" or "notes")
			local header = string.format("%s %s%s", expander, target, count)
			local target_start = #expander + 1
			table.insert(lines, header)
			table.insert(spans, {
				line = #lines - 1,
				start_col = 0,
				end_col = #expander,
				hl_group = "AtlasTextMuted",
			})
			table.insert(spans, {
				line = #lines - 1,
				start_col = target_start,
				end_col = target_start + #target,
				hl_group = "AtlasLogInfo",
			})
			table.insert(spans, {
				line = #lines - 1,
				start_col = target_start + #target,
				end_col = #header,
				hl_group = "AtlasTextMuted",
			})
			line_map[#lines] = {
				target = document.target,
				tree_key = key,
			}

			if expanded then
				local offset = #lines
				local note_lines, note_spans, note_map = M.render_list(items, opts.width, {
					padding_x = 4,
					action_keys = opts.action_keys,
				})
				utils.append_block(lines, spans, { lines = note_lines, highlights = note_spans })
				for line, entry in pairs(note_map) do
					line_map[offset + line] = entry
				end
			end
		end
	end

	if #lines == 0 then
		local message = "No notes found"
		if opts.filter_label then
			message = string.format("%s for %s", message, opts.filter_label)
		end
		return { message .. "." }, {}, {}
	end

	return lines, spans, line_map
end

return M
