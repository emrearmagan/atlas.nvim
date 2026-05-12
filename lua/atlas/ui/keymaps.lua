local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")

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
	local items = {
		{
			key = "j",
			desc = "Next item",
			hidden = true,
			callback = function()
				require("atlas.ui.navigation").move_cursor("down")
			end,
		},
		{
			key = "k",
			desc = "Previous item",
			hidden = true,
			callback = function()
				require("atlas.ui.navigation").move_cursor("up")
			end,
		},
		{
			key = "gg",
			desc = "Go to first item",
			hidden = true,
			callback = function()
				require("atlas.ui.navigation").focus_first_item()
			end,
		},
		{
			key = "G",
			desc = "Go to last item",
			hidden = true,
			callback = function()
				require("atlas.ui.navigation").focus_last_item()
			end,
		},
	}

	utils.insert_if(items, item("ui.help", {
		desc = "Toggle this help popup",
		opts = { nowait = true, silent = true },
		callback = function()
			help.toggle({ buffer = buf })
		end,
	}))

	utils.insert_if(items, item("ui.close", {
		desc = "Close Atlas window",
		opts = { nowait = true, silent = true },
		callback = function()
			if help.is_open() then
				return
			end
			require("atlas.ui.layout").close()
		end,
	}))

	utils.insert_if(items, item("ui.toggle_panel", {
		desc = "Toggle detail panel",
		callback = function()
			local layout_mod = require("atlas.ui.layout")
			local ui_st = require("atlas.ui.state")
			local was_open = layout_mod.win_id("detail") ~= nil
			layout_mod.toggle_detail()
			if was_open then
				if ui_st.on_panel_close then
					ui_st.on_panel_close()
				end
			else
				if ui_st.on_panel_open then
					ui_st.on_panel_open()
				end
			end
		end,
	}))

	utils.insert_if(items, item("ui.next_panel_tab", {
		desc = "Next panel tab",
		opts = { nowait = true },
		callback = function()
			local layout_mod = require("atlas.ui.layout")
			local ui_st = require("atlas.ui.state")
			if layout_mod.win_id("detail") ~= nil and ui_st.on_panel_next_tab then
				ui_st.on_panel_next_tab()
			end
		end,
	}))

	utils.insert_if(items, item("ui.previous_panel_tab", {
		desc = "Previous panel tab",
		opts = { nowait = true },
		callback = function()
			local layout_mod = require("atlas.ui.layout")
			local ui_st = require("atlas.ui.state")
			if layout_mod.win_id("detail") ~= nil and ui_st.on_panel_prev_tab then
				ui_st.on_panel_prev_tab()
			end
		end,
	}))

	utils.insert_if(items, item("ui.open_notifications", {
		desc = "Open notifications",
		callback = function()
			require("atlas.ui.notifications").open()
		end,
	}))

	M.remove(buf)
	help.register("General", items, { index = 210, buffer = buf })
end

---@param buf integer
function M.remove(buf)
	local items = {
		{ key = "j" },
		{ key = "k" },
		{ key = "gg" },
		{ key = "G" },
	}
	utils.insert_if(items, remove_item("ui.help"))
	utils.insert_if(items, remove_item("ui.close"))
	utils.insert_if(items, remove_item("ui.toggle_panel"))
	utils.insert_if(items, remove_item("ui.next_panel_tab"))
	utils.insert_if(items, remove_item("ui.previous_panel_tab"))
	utils.insert_if(items, remove_item("ui.open_notifications"))

	help.remove("General", items, { buffer = buf })
end

return M
