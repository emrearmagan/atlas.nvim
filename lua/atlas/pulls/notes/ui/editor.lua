local code_preview = require("atlas.ui.components.code_preview")
local notes = require("atlas.pulls.notes")
local popup_editor = require("atlas.ui.popups.editor")
local info = require("atlas.ui.popups.info")
local renderer = require("atlas.pulls.notes.ui.renderer")

local M = {}

---@param value AtlasNoteInput|AtlasNote
---@return AtlasEditorPreview|nil
local function context_preview(value)
	local context = value.context
	if not context then
		return nil
	end
	return code_preview.render({
		file_path = value.file_path,
		lines = context.lines,
		start_line = context.start_line,
		anchor_start = value.start_line,
		anchor_line = value.end_line,
	})
end

---@param value AtlasNoteInput|AtlasNote
---@param key string
---@param on_save fun(body: string, note_type: AtlasNoteType)
local function open_body_editor(value, key, on_save)
	local note_type = value.type or "note"
	local function window_title()
		return " " .. renderer.note_title(note_type, value) .. " "
	end
	popup_editor.open({
		key = key,
		title = window_title(),
		title_pos = "left",
		initial_text = value.body or "",
		width_ratio = 0.7,
		height_ratio = 0.5,
		preview = context_preview(value),
		actions = {
			{
				key = "!",
				description = "type",
				callback = function(editor_context)
					local index = vim.fn.index(notes.types, note_type)
					note_type = notes.types[(index + 1) % #notes.types + 1]
					vim.api.nvim_win_set_config(editor_context.win, { title = window_title(), title_pos = "left" })
				end,
			},
		},
		on_save = function(body)
			on_save(body, note_type)
		end,
	})
end

---@param target AtlasStorageTarget
---@param input AtlasNoteInput
---@param on_done fun(note: AtlasNote|nil, err: string|nil)
function M.create(target, input, on_done)
	open_body_editor(input, "atlas-note-create", function(body, note_type)
		input.body = body
		input.type = note_type
		on_done(notes.add(target, input))
	end)
end

---@param target AtlasStorageTarget
---@param note AtlasNote
---@param on_done fun(note: AtlasNote|nil, err: string|nil)
function M.edit(target, note, on_done)
	open_body_editor(note, "atlas-note-edit-" .. note.id, function(body, selected)
		on_done(notes.update(target, note.id, {
			body = body,
			type = selected,
		}))
	end)
end

---@param note AtlasNote
---@param target AtlasStorageTarget
---@param source_buf integer
function M.details(note, target, source_buf)
	local lines, highlights = renderer.render_details(note, target, math.max(10, vim.o.columns - 4))
	info.show({
		lines = lines,
		highlights = highlights,
		source_buf = source_buf,
	})
end

return M
