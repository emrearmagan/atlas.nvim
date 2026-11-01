local M = {}

local window = require("atlas.issues.ui.dashboard.window")
local dashboard = require("atlas.issues.ui.dashboard")

---@param provider IssuesProvider
---@param opts { initial_view: IssuesViewConfig|nil }|nil
function M.open(provider, opts)
	window.open()
	dashboard.init(provider, opts)
end

return M
