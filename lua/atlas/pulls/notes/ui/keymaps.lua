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
---@param description string
---@param index integer
---@param callback function
---@param options { mode: string[]|nil, silent: boolean|nil }|nil
local function add(items, action, description, index, callback, options)
	local keys = resolver.resolve(action)
	if not keys then
		return
	end
	table.insert(items, {
		key = keys,
		mode = options and options.mode,
		desc = description,
		index = index,
		callback = callback,
		opts = { nowait = true, silent = options and options.silent },
	})
end

---@param buf integer
---@param actions AtlasNotesUIActions
function M.register(buf, actions)
	local note_actions = {}
	add(note_actions, "ui.show_details", "Show note details", 1, actions.details)
	add(note_actions, "ui.comments.edit", "Edit note", 2, actions.edit)
	add(note_actions, "ui.delete", "Delete selected notes", 3, actions.delete, { mode = { "n", "x" } })
	add(note_actions, "ui.toggle_fold", "Expand / collapse", 4, actions.toggle, { silent = true })
	help.register("Notes", note_actions, { buffer = buf, index = 100 })
	local view = {}
	add(view, "ui.refresh_view", "Reload notes", 5, actions.refresh)
	add(view, "ui.help", "Toggle help", 6, function()
		help.toggle({ buffer = buf })
	end)
	add(view, "ui.close", "Close notes", 7, actions.close)
	help.register("View", view, { buffer = buf, index = 110 })
end

return M
