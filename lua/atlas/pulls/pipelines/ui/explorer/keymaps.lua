local M = {}

local keymaps = require("atlas.core.keymaps")
local explorer = require("atlas.pulls.pipelines.ui.explorer")

---@param pane PullsPipelinesExplorer
---@param content_win integer
---@return AtlasHelpKeyItem[]
function M.items(pane, content_win)
	local items = {}
	for index, item in ipairs({
		{
			key = keymaps.resolve("ui.select") or {},
			desc = "Open logs",
			callback = function()
				if explorer.select(pane) then
					vim.api.nvim_set_current_win(content_win)
				end
			end,
		},
		{
			key = keymaps.resolve("ui.show_details") or {},
			desc = "Preview logs",
			callback = function()
				explorer.select(pane)
			end,
		},
		{
			key = keymaps.resolve("ui.refresh_view") or {},
			desc = "Refresh latest pipelines",
			callback = function()
				explorer.refresh(pane)
			end,
		},
		{
			key = keymaps.resolve("ui.refresh") or {},
			desc = "Refresh job under cursor",
			callback = function()
				explorer.reload_job(pane)
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
