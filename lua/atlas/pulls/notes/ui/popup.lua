local keymaps = require("atlas.core.keymaps")
local editor = require("atlas.pulls.notes.ui.editor")
local notes = require("atlas.pulls.notes")
local renderer = require("atlas.pulls.notes.ui.renderer")
local statusline = require("atlas.ui.statusline")

local M = {}

local namespace = vim.api.nvim_create_namespace("atlas.notes.popup")
local current_win

---@class AtlasNotesUIChange
---@field kind "upsert"|"delete"
---@field note AtlasNote|nil
---@field id string

---@class AtlasNotesUIPopupOptions
---@field target AtlasNoteTarget
---@field notes AtlasNote[]
---@field outdated table<string, boolean>|nil
---@field on_change fun(change: AtlasNotesUIChange)
---@field notify fun(level: "success"|"error", message: string)

function M.close()
	if current_win and vim.api.nvim_win_is_valid(current_win) then
		vim.api.nvim_win_close(current_win, true)
	end
	current_win = nil
end

---@param opts AtlasNotesUIPopupOptions
function M.open(opts)
	M.close()
	local source_win = vim.api.nvim_get_current_win()
	local keys = {
		close = keymaps.resolve("ui.close"),
		edit = keymaps.resolve("pulls.review.diff.edit_comment"),
		delete = keymaps.resolve("pulls.review.diff.delete"),
	}
	local width = math.max(1, math.min(100, vim.o.columns - 4))
	local lines, spans, line_map = renderer.render_cards(opts.notes, width, {
		action_keys = {
			edit = keys.edit and table.concat(keys.edit, " / ") or nil,
			delete = keys.delete and table.concat(keys.delete, " / ") or nil,
		},
		boxed = false,
		padding_x = 1,
		outdated = opts.outdated,
	})
	local height = math.max(1, math.min(#lines, vim.o.lines - 6))
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(buf, namespace, span.line, span.start_col, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " Local notes ",
		title_pos = "center",
		zindex = 250,
	})
	current_win = win
	vim.api.nvim_set_option_value(
		"winhighlight",
		"Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat,FloatBorder:FloatBorder",
		{ win = win }
	)
	vim.api.nvim_set_option_value("cursorline", true, { win = win })
	vim.api.nvim_set_option_value("wrap", false, { win = win })
	statusline.inherit(win, source_win)

	local function selected_note()
		local item = line_map[vim.api.nvim_win_get_cursor(win)[1]]
		return item and item.note or nil
	end

	local function edit()
		local note = selected_note()
		if not note then
			return
		end
		M.close()
		editor.edit(opts.target, note, function(updated, err)
			if not updated then
				opts.notify("error", err or "Unable to update local note")
				return
			end
			opts.on_change({ kind = "upsert", note = updated, id = updated.id })
			opts.notify("success", "Local note updated")
		end)
	end

	local function delete()
		local note = selected_note()
		if not note then
			return
		end
		M.close()
		vim.ui.input({ prompt = "Delete local note? [y/N]: " }, function(answer)
			answer = vim.trim(tostring(answer or "")):lower()
			if answer ~= "y" and answer ~= "yes" then
				return
			end
			local deleted, err = notes.delete(opts.target, note.id)
			if not deleted then
				opts.notify("error", err or "Unable to delete local note")
				return
			end
			opts.on_change({ kind = "delete", note = nil, id = note.id })
			opts.notify("success", "Local note deleted")
		end)
	end

	local key_opts = { buffer = buf, silent = true, nowait = true }
	local function map(keys_to_map, callback)
		for _, key in ipairs(keys_to_map or {}) do
			vim.keymap.set("n", key, callback, key_opts)
		end
	end
	map(keys.close, M.close)
	vim.keymap.set("n", "<Esc>", M.close, key_opts)
	map(keys.edit, edit)
	map(keys.delete, delete)
end

return M
