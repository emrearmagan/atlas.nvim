local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")

local M = {}

---@class AtlasNotesUIActions
---@field toggle fun()
---@field details fun()
---@field edit fun()
---@field delete fun()
---@field refresh fun()
---@field close fun()

---@param items AtlasHelpKeyItem[]
---@param action AtlasKeymapActionId
---@param index integer
---@param callback function
---@param options { mode: string[]|nil, silent: boolean|nil }|nil
local function add(items, action, index, callback, options)
	local keymap = resolver.resolve(action)
	if not keymap then
		return
	end
	table.insert(items, {
		key = keymap.key,
		mode = options and options.mode,
		desc = keymap.desc,
		index = index,
		callback = callback,
		opts = { nowait = true, silent = options and options.silent },
	})
end

---@param buf integer
---@param actions AtlasNotesUIActions
function M.register(buf, actions)
	local note_actions = {}
	add(note_actions, "ui.show_details", 1, actions.details)
	add(note_actions, "ui.comments.edit", 2, actions.edit)
	add(note_actions, "ui.delete", 3, actions.delete, { mode = { "n", "x" } })
	add(note_actions, "ui.toggle_fold", 4, actions.toggle, { silent = true })
	help.register("Notes", note_actions, { buffer = buf, index = 100 })
	local view = {}
	add(view, "ui.refresh_view", 5, actions.refresh)
	add(view, "ui.help", 6, function()
		help.toggle({ buffer = buf })
	end)
	add(view, "ui.close", 7, actions.close)
	help.register("View", view, { buffer = buf, index = 110 })
end

return M
