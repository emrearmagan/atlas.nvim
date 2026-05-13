local M = {}

---@param provider IssuesProvider
---@param opts? { initial_view?: IssuesViewConfig }
function M.init(provider, opts)
	local main = require("atlas.issues.ui.main")
	main.init(provider, opts)
end

function M.render()
	local main = require("atlas.issues.ui.main")
	main.render()
end

return M
