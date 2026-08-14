---@class PullsRepoBranchesTabState
---@field repo PullsRepoDetails|nil
---@field branches PullsRepoBranches|"loading"|string|nil
---@field line_map table<integer, table>
local M = {
	repo = nil,
	branches = nil,
	line_map = {},
}

function M.reset()
	M.repo = nil
	M.branches = nil
	M.line_map = {}
end

return M
