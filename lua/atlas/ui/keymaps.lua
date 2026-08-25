local M = {}

local help = require("atlas.ui.popups.help")
local navigation = require("atlas.ui.navigation")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")

local function domain_dashboard()
	local domain = require("atlas.ui.state").domain
	return domain and require("atlas." .. domain .. ".ui.dashboard") or nil
end

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
---@param mode string|string[]|nil
---@return table|nil
local function remove_item(action_id, mode)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end

	local out = { key = (#keys == 1 and keys[1] or keys) }
	if mode ~= nil then
		out.mode = mode
	end
	return out
end

---@param buf integer
function M.register(buf)
	local items = {}

	utils.insert_if(
		items,
		item("ui.next_item", {
			desc = "Next item",
			hidden = true,
			callback = function()
				navigation.move_cursor("down")
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.previous_item", {
			desc = "Previous item",
			hidden = true,
			callback = function()
				navigation.move_cursor("up")
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.first_item", {
			desc = "Go to first item",
			hidden = true,
			callback = function()
				navigation.focus_first_item()
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.last_item", {
			desc = "Go to last item",
			hidden = true,
			callback = function()
				navigation.focus_last_item()
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.help", {
			desc = "Toggle this help popup",
			opts = { nowait = true, silent = true },
			callback = function()
				help.toggle({ buffer = buf })
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.close", {
			desc = "Close Atlas window",
			opts = { nowait = true, silent = true },
			callback = function()
				if help.is_open() then
					return
				end
				require("atlas.ui.dashboard").close()
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.toggle_panel", {
			desc = "Toggle detail panel",
			callback = function()
				local dashboard = domain_dashboard()
				if dashboard then
					dashboard.toggle_detail()
				end
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.next_panel_tab", {
			desc = "Next panel tab",
			opts = { nowait = true },
			callback = function()
				local dashboard = domain_dashboard()
				if dashboard then
					dashboard.next_detail_tab()
				end
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.previous_panel_tab", {
			desc = "Previous panel tab",
			opts = { nowait = true },
			callback = function()
				local dashboard = domain_dashboard()
				if dashboard then
					dashboard.prev_detail_tab()
				end
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.notifications.open", {
			desc = "Open notifications",
			callback = function()
				require("atlas.ui.notifications").open()
			end,
		})
	)

	M.remove(buf)
	navigation.attach(buf)
	help.register("General", items, { index = 210, buffer = buf })
end

---@param buf integer
function M.remove(buf)
	navigation.detach(buf)
	local items = {}
	utils.insert_if(items, remove_item("ui.next_item"))
	utils.insert_if(items, remove_item("ui.previous_item"))
	utils.insert_if(items, remove_item("ui.first_item"))
	utils.insert_if(items, remove_item("ui.last_item"))
	utils.insert_if(items, remove_item("ui.help"))
	utils.insert_if(items, remove_item("ui.close"))
	utils.insert_if(items, remove_item("ui.toggle_panel"))
	utils.insert_if(items, remove_item("ui.next_panel_tab"))
	utils.insert_if(items, remove_item("ui.previous_panel_tab"))
	utils.insert_if(items, remove_item("ui.notifications.open"))

	help.remove("General", items, { buffer = buf })
end

return M
