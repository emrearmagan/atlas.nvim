local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local pipelines = require("atlas.pulls.pipelines")
local utils = require("atlas.ui.shared.utils")
local detail = require("atlas.pulls.ui.detail.state")
local state = require("atlas.pulls.ui.detail.tabs.overview.state")

---@param action_id AtlasKeymapActionId|AtlasKeymapActionId[]
---@param map_item table
---@return table|nil
local function item(action_id, map_item)
	local keymap = resolver.resolve(action_id)
	if keymap == nil then
		return nil
	end
	map_item.key = keymap.key
	map_item.desc = keymap.desc
	return map_item
end

---@param action_id AtlasKeymapActionId|AtlasKeymapActionId[]
---@return table|nil
local function remove_item(action_id)
	local keymap = resolver.resolve(action_id)
	if keymap == nil then
		return nil
	end
	return { key = keymap.key }
end

---@param buf integer
---@param refresh fun()
function M.setup(buf, refresh)
	local items = {}
	utils.insert_if(
		items,
		item("ui.toggle_description_mode", {
			index = 11,
			opts = { nowait = true, silent = true },
			callback = function()
				state.view_mode = state.view_mode == "raw" and "markdown" or "raw"
				refresh()
			end,
		})
	)
	utils.insert_if(
		items,
		item("ui.toggle_fold", {
			index = 10,
			opts = { nowait = true, silent = true },
			callback = function()
				state.description_expanded = not state.description_expanded
				refresh()
			end,
		})
	)
	utils.insert_if(
		items,
		item({ "ui.show_details", "ui.select" }, {
			index = 1,
			opts = { nowait = true, silent = true },
			callback = function()
				local lnum = vim.api.nvim_win_get_cursor(0)[1]
				local entry = detail.line_map[lnum]
				local pr = detail.current_pr
				if pr and entry and entry.pipeline then
					pipelines.open(pr, detail.provider, {
						selected_pipeline = entry.pipeline,
						selected_stage = entry.stage,
						selected_job = entry.job,
					})
				end
			end,
		})
	)
	help.register("Detail", items, { index = 2, buffer = buf })
end

---@param buf integer
function M.teardown(buf)
	local items = {}
	utils.insert_if(items, remove_item("ui.toggle_description_mode"))
	utils.insert_if(items, remove_item("ui.toggle_fold"))
	utils.insert_if(items, remove_item({ "ui.show_details", "ui.select" }))
	help.remove("Detail", items, { buffer = buf })
end

return M
