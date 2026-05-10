---@class GHIssuesActivityState
---@field issue Issue|nil
---@field activity GHIssueTimelineEntry[]|"loading"|string|nil
local M = {
	issue = nil,
	activity = nil,
}

function M.reset()
	M.issue = nil
	M.activity = nil
end

---@return boolean
function M.any_loading()
	return M.activity == "loading"
end

return M
