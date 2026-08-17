local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local actions = require("atlas.pulls.actions")

---@param action_id AtlasKeymapActionId|string
---@param map_item table
---@return table|nil
local function item(action_id, map_item)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end
	map_item.key = #keys == 1 and keys[1] or keys
	return map_item
end

---@param id "edit_reviewers"|"edit_assignees"
---@param pr PullRequest
local function run_action(id, pr)
	local state = require("atlas.pulls.state")
	if state.provider then
		actions.run(id, {
			provider = state.provider,
			pr = pr,
			current_user = state.current_user,
		}, function(result)
			require("atlas.pulls.ui.main.controller").apply_action_result(pr, result)
		end)
	end
end

---@param buf integer
function M.register(buf)
	local panel_state = require("atlas.pulls.ui.panel.pr.state")
	local items = {}
	utils.insert_if(
		items,
		item("pulls.edit_reviewers", {
			desc = "Edit reviewers",
			opts = { nowait = true },
			callback = function()
				local pr = panel_state.current_pr
				if pr == nil then
					return
				end
				run_action("edit_reviewers", pr)
			end,
		})
	)
	utils.insert_if(
		items,
		item("pulls.edit_assignees", {
			desc = "Edit assignees",
			opts = { nowait = true },
			callback = function()
				local pr = panel_state.current_pr
				if pr == nil then
					return
				end
				run_action("edit_assignees", pr)
			end,
		})
	)

	help.register("Panel", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.remove(buf)
	local items = {}
	utils.insert_if(items, item("pulls.edit_reviewers", {}))
	utils.insert_if(items, item("pulls.edit_assignees", {}))
	help.remove("Panel", items, { buffer = buf })
end

return M
