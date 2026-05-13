local M = {}

local main = require("atlas.pulls.ui.main")

---@param provider PullsProvider
---@param opts? { initial_view?: AtlasPullsViewConfig }
function M.init(provider, opts)
	main.init(provider, opts)
end

function M.render()
	main.render()
end

return M
