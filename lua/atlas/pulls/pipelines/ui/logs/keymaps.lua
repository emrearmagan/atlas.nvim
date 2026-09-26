local M = {}

local keymaps = require("atlas.core.keymaps")
local logs = require("atlas.pulls.pipelines.ui.logs")

---@param pane PullsPipelinesLogs
---@return AtlasHelpKeyItem[]
function M.items(pane)
	local items = {}
	for index, item in ipairs({
		{
			key = keymaps.resolve("ui.refresh") or {},
			desc = "Refresh job and logs",
			callback = function()
				if pane.selection and pane.on_reload then
					pane.on_reload(pane.selection)
				end
			end,
		},
		{
			key = keymaps.resolve("ui.toggle_fold") or {},
			desc = "Toggle log group",
			callback = function()
				logs.toggle_fold(pane)
			end,
		},
		{
			key = keymaps.resolve("ui.toggle_all_folds") or {},
			desc = "Toggle all log groups",
			callback = function()
				logs.toggle_all_folds(pane)
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
