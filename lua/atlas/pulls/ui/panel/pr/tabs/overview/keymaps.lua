local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local panel_state = require("atlas.pulls.ui.panel.pr.state")
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
	utils.insert_if(
		items,
		item("ui.toggle_fold", {
			desc = "Toggle description or pipeline",
			opts = { nowait = true, silent = true },
			callback = function()
				local lnum = vim.api.nvim_win_get_cursor(0)[1]
				local entry = (panel_state.line_map or {})[lnum]
				if entry and entry.kind == "pipeline" and entry.pipeline and state.toggle_pipeline(entry.pipeline) then
					refresh()
				elseif entry and entry.kind == "description" then
					state.description_expanded = not state.description_expanded
					refresh()
				end
			end,
		})
	)
	utils.insert_if(
		items,
		item("ui.show_details", {
			desc = "Show pipeline details",
			opts = { nowait = true, silent = true },
			callback = function()
				local lnum = vim.api.nvim_win_get_cursor(0)[1]
				local entry = (panel_state.line_map or {})[lnum]
				local pr = panel_state.current_pr
				if pr and entry and entry.kind == "pipeline" and entry.pipeline then
					local pipelines = type(panel_state.pipelines) == "table" and panel_state.pipelines
						or { entry.pipeline }
					require("atlas.pulls.ui.pipelines").open(pr, pipelines, entry.pipeline, entry.job)
				end
			end,
		})
	)
	help.register("Panel", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.teardown(buf)
	local items = {}
	utils.insert_if(items, remove_item("ui.toggle_fold"))
	utils.insert_if(items, remove_item("ui.show_details"))
	help.remove("Panel", items, { buffer = buf })
end

return M
