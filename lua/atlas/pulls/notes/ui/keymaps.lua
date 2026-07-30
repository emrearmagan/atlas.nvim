local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")

local M = {}

---@class AtlasNotesUIActions
---@field details fun()
---@field edit fun()
---@field delete fun()
---@field refresh fun()
---@field close fun()

---@param buf integer
---@param actions AtlasNotesUIActions
function M.register(buf, actions)
	help.register("Notes", {
		{ key = "K", desc = "Show note details", index = 1, callback = actions.details, opts = { nowait = true } },
		{ key = "e", desc = "Edit note", index = 2, callback = actions.edit, opts = { nowait = true } },
		{
			key = "d",
			mode = { "n", "x" },
			desc = "Delete selected notes",
			index = 3,
			callback = actions.delete,
			opts = { nowait = true },
		},
	}, { buffer = buf, index = 100 })
	local view = {
		{ key = "R", desc = "Reload notes", index = 4, callback = actions.refresh, opts = { nowait = true } },
		{ key = "q", desc = "Close notes", index = 6, callback = actions.close, opts = { nowait = true } },
	}
	local help_keys = resolver.resolve("ui.help")
	if help_keys then
		table.insert(view, {
			key = #help_keys == 1 and help_keys[1] or help_keys,
			desc = "Toggle help",
			index = 5,
			callback = function()
				help.toggle({ buffer = buf })
			end,
			opts = { nowait = true },
		})
	end
	help.register("View", view, { buffer = buf, index = 110 })
end

return M
