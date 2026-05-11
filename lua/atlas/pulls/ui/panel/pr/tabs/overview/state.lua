---@class PullsOverviewState
---@field reviewers PullsReviewer[]|"loading"|string|nil
---@field builds PullsBuild[]|"loading"|string|nil
---@field description string|"loading"|nil
---@field merge_checks PullsMergeCheck[]|"loading"|string|nil
local M = {
	reviewers = nil,
	builds = nil,
	description = nil,
	merge_checks = nil,
}

function M.reset()
	M.reviewers = nil
	M.builds = nil
	M.description = nil
	M.merge_checks = nil
end

---@return boolean
function M.any_loading()
	return M.reviewers == "loading"
		or M.builds == "loading"
		or M.description == "loading"
		or M.merge_checks == "loading"
end

return M
