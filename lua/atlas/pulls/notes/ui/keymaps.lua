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

---@param buf integer
---@param actions AtlasNotesUIActions
function M.register(buf, actions)
	local note_actions = {}
	local details_keys = resolver.resolve("ui.show_details")
	if details_keys then
		table.insert(note_actions, {
			key = #details_keys == 1 and details_keys[1] or details_keys,
			desc = "Show note details",
			index = 1,
			callback = actions.details,
			opts = { nowait = true },
		})
	end
	local edit_keys = resolver.resolve("ui.comments.edit")
	if edit_keys then
		table.insert(note_actions, {
			key = #edit_keys == 1 and edit_keys[1] or edit_keys,
			desc = "Edit note",
			index = 2,
			callback = actions.edit,
			opts = { nowait = true },
		})
	end
	local delete_keys = resolver.resolve("ui.delete")
	if delete_keys then
		table.insert(note_actions, {
			key = #delete_keys == 1 and delete_keys[1] or delete_keys,
			mode = { "n", "x" },
			desc = "Delete selected notes",
			index = 3,
			callback = actions.delete,
			opts = { nowait = true },
		})
	end
	local fold_keys = resolver.resolve("ui.toggle_fold")
	if fold_keys then
		table.insert(note_actions, {
			key = #fold_keys == 1 and fold_keys[1] or fold_keys,
			desc = "Expand / collapse",
			index = 4,
			callback = actions.toggle,
			opts = { nowait = true, silent = true },
		})
	end
	help.register("Notes", note_actions, { buffer = buf, index = 100 })
	local view = {}
	local refresh_keys = resolver.resolve("ui.refresh_view")
	if refresh_keys then
		table.insert(view, {
			key = #refresh_keys == 1 and refresh_keys[1] or refresh_keys,
			desc = "Reload notes",
			index = 5,
			callback = actions.refresh,
			opts = { nowait = true },
		})
	end
	local help_keys = resolver.resolve("ui.help")
	if help_keys then
		table.insert(view, {
			key = #help_keys == 1 and help_keys[1] or help_keys,
			desc = "Toggle help",
			index = 6,
			callback = function()
				help.toggle({ buffer = buf })
			end,
			opts = { nowait = true },
		})
	end
	local close_keys = resolver.resolve("ui.close")
	if close_keys then
		table.insert(view, {
			key = #close_keys == 1 and close_keys[1] or close_keys,
			desc = "Close notes",
			index = 7,
			callback = actions.close,
			opts = { nowait = true },
		})
	end
	help.register("View", view, { buffer = buf, index = 110 })
end

return M
