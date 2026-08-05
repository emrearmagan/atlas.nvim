---@class PullsPanelState
---@field current_pr PullRequest|nil
---@field current_repo PullsRepo|nil
---@field current_tab string|nil
---@field line_map table<integer, table>
---@field diffstat PullsDiffstatEntry[]|"loading"|string|nil
local M = {
	current_pr = nil,
	current_repo = nil,
	current_tab = nil,
	line_map = {},
	diffstat = nil,
}

function M.reset()
	M.current_pr = nil
	M.current_repo = nil
	M.current_tab = "overview"
	M.line_map = {}
	M.diffstat = nil
end

return M
