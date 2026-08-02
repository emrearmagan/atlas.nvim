local notes = require("atlas.pulls.notes")
local popup_editor = require("atlas.ui.popups.editor")
local info = require("atlas.ui.popups.info")
local renderer = require("atlas.pulls.notes.ui.renderer")
local code_preview = require("atlas.ui.components.code_preview")

local M = {}

---@param note_type AtlasNoteType|nil
---@param file_path string
---@param line integer
---@param initial_text string
---@param key string
---@param context AtlasNoteContext|nil
---@param on_save fun(body: string, note_type: AtlasNoteType)
local function open_body_editor(note_type, file_path, line, initial_text, key, context, on_save)
	note_type = note_type or "note"
	local function window_title()
		return " " .. renderer.note_title(note_type, file_path, line) .. " "
	end
	local preview = context
		and code_preview.render({
			file_path = file_path,
			lines = context.lines,
			start_line = context.start_line,
			anchor_line = line,
		})
	popup_editor.open({
		key = key,
		title = window_title(),
		title_pos = "left",
		initial_text = initial_text,
		width_ratio = 0.5,
		height_ratio = 0.18,
		preview = preview,
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

---@param target AtlasNoteTarget
---@param input AtlasNoteInput
---@param on_done fun(note: AtlasNote|nil, err: string|nil)
function M.create(target, input, on_done)
	open_body_editor(
		input.type,
		input.file_path,
		input.line,
		input.body or "",
		"atlas-note-create",
		input.context,
		function(body, note_type)
			input.body = body
			input.type = note_type
			on_done(notes.add(target, input))
		end
	)
end

---@param target AtlasNoteTarget
---@param note AtlasNote
---@param on_done fun(note: AtlasNote|nil, err: string|nil)
function M.edit(target, note, on_done)
	open_body_editor(
		note.type,
		note.file_path,
		note.line,
		note.body,
		"atlas-note-edit-" .. note.id,
		note.context,
		function(body, selected)
			on_done(notes.update(target, note.id, {
				body = body,
				type = selected,
			}))
		end
	)
end

---@param note AtlasNote
---@param target AtlasNoteTarget
---@param source_buf integer
function M.details(note, target, source_buf)
	local lines, highlights = renderer.render_details(note, target)
	info.show({
		lines = lines,
		highlights = highlights,
		source_buf = source_buf,
	})
end

return M
