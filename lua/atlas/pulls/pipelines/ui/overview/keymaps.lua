local M = {}

local keymaps = require("atlas.core.keymaps")
local explorer = require("atlas.pulls.pipelines.ui.explorer")
local overview = require("atlas.pulls.pipelines.ui.overview")

---@param pane PullsPipelinesOverview
---@param explorer_pane PullsPipelinesExplorer
---@return AtlasHelpKeyItem[]
function M.items(pane, explorer_pane)
	local items = {}
	for index, binding in ipairs({
		{
			keymap = keymaps.resolve("ui.select"),
			callback = function()
				local selection = overview.current_selection(pane)
				if selection then
					explorer.render(explorer_pane, selection)
					explorer.select(explorer_pane)
				end
			end,
		},
	}) do
		if binding.keymap then
			items[#items + 1] = {
				key = binding.keymap.key,
				desc = binding.keymap.desc,
				callback = binding.callback,
				index = index,
				opts = { nowait = true, silent = true },
			}
		end
	end
	return items
end

return M
