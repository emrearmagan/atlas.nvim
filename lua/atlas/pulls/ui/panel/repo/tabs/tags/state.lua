---@class PullsRepoTagsTabState
---@field repo PullsRepoDetails|nil
---@field tags PullsRepoTags|"loading"|string|nil
---@field line_map table<integer, table>
local M = {
	repo = nil,
	tags = nil,
	line_map = {},
}

function M.reset()
	M.repo = nil
	M.tags = nil
	M.line_map = {}
end

return M
