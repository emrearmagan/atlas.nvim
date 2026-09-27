local request_scope = require("atlas.core.requests")

---@class PullsOverviewState
---@field reviewers PullsReviewer[]|"loading"|string|nil
---@field description_expanded boolean
---@field view_mode "markdown"|"raw"
---@field requests AtlasRequestScope
local M = {
	reviewers = nil,
	description_expanded = false,
	view_mode = "markdown",
	requests = request_scope.new(),
}

function M.reset()
	M.reviewers = nil
	M.description_expanded = false
	M.requests.cancel()
	M.requests = request_scope.new()
end

return M
