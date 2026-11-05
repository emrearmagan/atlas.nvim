local M = {}

local keymaps = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")

---@class AtlasFormKeymap
---@field keymap AtlasKeymapActionId
---@field mode string|string[]|nil
---@field action fun(form: AtlasForm)

---@param opts AtlasFormOpenOpts
---@return AtlasKeymapActionId[]
function M.hints(opts)
	local hints = { "ui.submit", "editor.templates" }
	for _, keymap in ipairs(opts.keymaps or {}) do
		hints[#hints + 1] = keymap.keymap
	end
	hints[#hints + 1] = "ui.close"
	return hints
end

---@param form AtlasForm
---@param on_close fun(form: AtlasForm)
---@param buffers integer[]|nil
function M.setup(form, on_close, buffers)
	local opts = form.opts
	local buf = form.editor_buf
	local help_keymap = keymaps.resolve("ui.help")
	local items = {}
	---@param keymap AtlasKeymap|nil
	local function add(keymap, callback, mode)
		if keymap then
			items[#items + 1] = {
				key = keymap.key,
				desc = keymap.desc,
				callback = callback,
				mode = mode,
				index = #items + 1,
				opts = { silent = true, nowait = true },
			}
		end
	end

	add(keymaps.resolve("ui.submit"), function()
		vim.cmd("stopinsert")
		opts.submit(form)
	end, { "n", "i" })
	add(keymaps.resolve("editor.templates"), function()
		local editor = require("atlas.ui.form")
		require("atlas.templates").open({
			get_description = function()
				return editor.get_content(form).body
			end,
			set_description = function(description)
				if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modifiable then
					return false
				end
				return editor.set_content(form, { body = description })
			end,
		})
	end)
	for _, keymap in ipairs(opts.keymaps or {}) do
		add(keymaps.resolve(keymap.keymap), function()
			keymap.action(form)
		end, keymap.mode)
	end
	add(help_keymap, function()
		help.toggle({ buffer = vim.api.nvim_get_current_buf() })
	end)
	local function close()
		on_close(form)
	end
	add(keymaps.resolve("ui.close"), close)
	for _, buffer in ipairs(buffers or { form.editor_buf, form.meta_buf }) do
		help.register("Form", items, { buffer = buffer, index = 100 })
		vim.api.nvim_buf_create_user_command(buffer, "AtlasEditorQuit", close, { desc = "Close Atlas editor" })
		vim.api.nvim_buf_call(buffer, function()
			vim.cmd("cnoreabbrev <buffer> q AtlasEditorQuit")
			vim.cmd("cnoreabbrev <buffer> quit AtlasEditorQuit")
		end)
	end
end

return M
