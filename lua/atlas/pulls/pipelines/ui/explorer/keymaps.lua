local M = {}

local keymaps = require("atlas.core.keymaps")
local explorer = require("atlas.pulls.pipelines.ui.explorer")

---@param pane PullsPipelinesExplorer
---@return AtlasHelpKeyItem[]
function M.items(pane)
	local items = {}
	local select_keys = keymaps.resolve("ui.select") or {}
	vim.list_extend(select_keys, keymaps.resolve("ui.show_details") or {})
	for index, item in ipairs({
		{
			key = select_keys,
			desc = "Show pipeline, job or step",
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
