local M = {}

local tabs = require("atlas.ui.components.tabs")

---@param items PullsDetailTab[]|PullsRepoDetailTab[]
---@param active_tab string
---@param opts { width: integer, padding_x?: integer }
---@return string[], table[]
function M.render(items, active_tab, opts)
	return tabs.render(items, active_tab, opts.width, {
		active_hl = nil,
		inactive_hl = "AtlasTextMuted",
		gap = " ",
		padding_x = opts.padding_x,
	})
end

return M
