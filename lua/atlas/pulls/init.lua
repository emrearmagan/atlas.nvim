local M = {}

local dashboard = require("atlas.pulls.ui.dashboard")

---@param provider PullsProvider
---@param opts? { initial_view?: AtlasPullsViewConfig }
function M.init(provider, opts)
	dashboard.init(provider, opts)
end

function M.render()
	dashboard.render()
end

function M.dispose()
	local buf = require("atlas.ui.dashboard").buf()
	if buf then
		require("atlas.pulls.ui.dashboard.keymaps").remove(buf)
	end
	require("atlas.pulls.ui.dashboard.controller").dispose()
end

return M
