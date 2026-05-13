local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")

---@param action_id AtlasKeymapActionId|string
---@param map_item table
---@return table|nil
local function item(action_id, map_item)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end
	local out = vim.tbl_deep_extend("force", {}, map_item)
	out.key = #keys == 1 and keys[1] or keys
	return out
end

---@param action_id AtlasKeymapActionId|string
---@return table|nil
local function remove_item(action_id)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end
	return { key = (#keys == 1 and keys[1] or keys) }
end

---@param buf integer
---@param refresh fun()
function M.setup(buf, refresh)
	local items = {}
	utils.insert_if(items, item("ui.toggle_fold", {
		desc = "Toggle description",
		opts = { nowait = true, silent = true },
		callback = function()
			state.description_expanded = not state.description_expanded
			refresh()
		end,
	}))
	help.register("Panel", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.teardown(buf)
	local items = {}
	utils.insert_if(items, remove_item("ui.toggle_fold"))
	help.remove("Panel", items, { buffer = buf })
end

return M
