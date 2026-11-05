local M = {}

local keymaps = require("atlas.core.keymaps")
local logs = require("atlas.pulls.pipelines.ui.logs")

---@param pane PullsPipelinesLogs
---@return AtlasHelpKeyItem[]
function M.items(pane)
	local items = {}
	for index, binding in ipairs({
		{
			keymap = keymaps.resolve("ui.refresh"),
			callback = function()
				if pane.selection and pane.on_reload then
					pane.on_reload(pane.selection)
				end
			end,
		},
		{
			keymap = keymaps.resolve("ui.toggle_fold"),
			callback = function()
				logs.toggle_fold(pane)
			end,
		},
		{
			keymap = keymaps.resolve("ui.toggle_all_folds"),
			callback = function()
				logs.toggle_all_folds(pane)
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
