local M = {}

local dashboard = require("atlas.pulls.ui.dashboard")
local window = require("atlas.pulls.ui.dashboard.window")

---@param provider PullsProvider
---@param opts { initial_view: AtlasPullsViewConfig|nil }|nil
function M.open(provider, opts)
	window.open()
	dashboard.init(provider, opts)
end

return M
