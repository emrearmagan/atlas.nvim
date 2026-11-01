local M = {}

local keymaps = require("atlas.core.keymaps")
local help = require("atlas.ui.popups.help")

---@class AtlasFormKeymap
---@field key string|string[]
---@field mode string|string[]|nil
---@field action fun(form: AtlasForm)
---@field desc string

---@param opts AtlasFormOpenOpts
---@return AtlasStatuslineSegment[]
function M.statusline_items(opts)
	local items = {}
	local function add(keys, label)
		if not keys then
			return
		end
		if #items > 0 then
			items[#items + 1] = { text = "|", hl_group = "AtlasFooterText" }
		end
		local key = type(keys) == "table" and table.concat(keys, " / ") or keys
		items[#items + 1] = { text = key, hl_group = "AtlasFooterBackground" }
		items[#items + 1] = { text = label, hl_group = "AtlasFooterText", priority = 10 }
	end

	add(keymaps.resolve("ui.submit"), "submit")
	add(keymaps.resolve("editor.templates"), "templates")
	for _, keymap in ipairs(opts.keymaps or {}) do
		add(keymap.key, keymap.desc)
	end
	add(keymaps.resolve("ui.close"), "close")

	return items
end

---@param form AtlasForm
---@param on_close fun(form: AtlasForm)
---@param buffers integer[]|nil
function M.setup(form, on_close, buffers)
	local opts = form.opts
	local buf = form.editor_buf
	local help_keys = keymaps.resolve("ui.help")
	form.statusline.options.help_key = help_keys and help_keys[1]
	local items = {}
	local function add(keys, desc, callback, mode)
		if keys then
			items[#items + 1] = {
				key = keys,
				desc = desc,
				callback = callback,
				mode = mode,
				index = #items + 1,
				opts = { silent = true, nowait = true },
			}
		end
	end

	add(keymaps.resolve("ui.submit"), "Submit", function()
		vim.cmd("stopinsert")
		opts.submit(form)
	end, { "n", "i" })
	add(keymaps.resolve("editor.templates"), "Templates", function()
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
		add(keymap.key, keymap.desc, function()
			keymap.action(form)
		end, keymap.mode)
	end
	add(help_keys, "Toggle help", function()
		help.toggle({ buffer = vim.api.nvim_get_current_buf() })
	end)
	local function close()
		on_close(form)
	end
	add(keymaps.resolve("ui.close"), "Close", close)
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
