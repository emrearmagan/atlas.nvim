---@class PullsRepoIssuesTabState
---@field issues PullsRepoIssue[]|"loading"|string|nil
---@field filter "open"|"closed"
---@field counts { open: integer, closed: integer }|nil
---@field repo_key string|nil
local M = {
	issues = nil,
	filter = "open",
	counts = nil,
	repo_key = nil,
}

function M.reset()
	M.issues = nil
	M.filter = "open"
	M.counts = nil
	M.repo_key = nil
end

return M
