local M = {}

local keymaps = require("atlas.core.keymaps")
local explorer = require("atlas.pulls.pipelines.ui.explorer")

---@param pane PullsPipelinesExplorer
---@param content_win integer
---@return AtlasHelpKeyItem[]
function M.items(pane, content_win)
	local items = {}
	for index, binding in ipairs({
		{
			keymap = keymaps.resolve("ui.select"),
			callback = function()
				if explorer.select(pane) then
					vim.api.nvim_set_current_win(content_win)
				end
			end,
		},
		{
			keymap = keymaps.resolve("ui.show_details"),
			callback = function()
				explorer.select(pane)
			end,
		},
		{
			keymap = keymaps.resolve("ui.refresh"),
			callback = function()
				explorer.reload_job(pane)
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
