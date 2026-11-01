local M = {}

local keymaps = require("atlas.core.keymaps")
local explorer = require("atlas.pulls.pipelines.ui.explorer")
local overview = require("atlas.pulls.pipelines.ui.overview")

---@param pane PullsPipelinesOverview
---@param explorer_pane PullsPipelinesExplorer
---@return AtlasHelpKeyItem[]
function M.items(pane, explorer_pane)
	local items = {}
	for index, item in ipairs({
		{
			key = keymaps.resolve("ui.select") or {},
			desc = "Open job logs",
			callback = function()
				local selection = overview.current_selection(pane)
				if selection then
					explorer.render(explorer_pane, selection)
					explorer.select(explorer_pane)
				end
			end,
		},
	}) do
		if #item.key > 0 then
			item.index = index
			item.opts = { nowait = true, silent = true }
			items[#items + 1] = item
		end
	end
	return items
end

return M
