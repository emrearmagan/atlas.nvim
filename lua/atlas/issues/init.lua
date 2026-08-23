local M = {}

---@param provider IssuesProvider
---@param opts? { initial_view?: IssuesViewConfig }
function M.init(provider, opts)
	local dashboard = require("atlas.issues.ui.dashboard")
	dashboard.init(provider, opts)
end

function M.render()
	require("atlas.issues.ui.dashboard").render()
end

function M.dispose()
	local buf = require("atlas.ui.dashboard").buf()
	if buf then
		require("atlas.issues.ui.dashboard.keymaps").remove(buf)
	end
	require("atlas.issues.ui.dashboard.controller").dispose()
end

return M
