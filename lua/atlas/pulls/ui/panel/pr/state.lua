---@class PullsPanelState
---@field current_pr PullRequest|nil
---@field current_repo PullsRepo|nil
---@field current_tab string|nil
---@field line_map table<integer, table>
---@field diffstat PullsDiffstatEntry[]|"loading"|string|nil
---@field pipelines PullsPipeline[]|"loading"|string|nil
---@field header_loading boolean
local M = {
	current_pr = nil,
	current_repo = nil,
	current_tab = nil,
	line_map = {},
	diffstat = nil,
	pipelines = nil,
	header_loading = false,
}

function M.reset()
	M.current_pr = nil
	M.current_repo = nil
	M.current_tab = "overview"
	M.line_map = {}
	M.diffstat = nil
	M.pipelines = nil
	M.header_loading = false
end

return M
