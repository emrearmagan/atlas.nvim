local request_scope = require("atlas.core.requests")

---@class PullsRepoDetailState
---@field current_repo PullsRepo|nil
---@field current_repo_details PullsRepoDetails|"loading"|string|nil
---@field current_tab string|nil
---@field tabs PullsRepoDetailTab[]
---@field line_map table<integer, table>
---@field win integer|nil
---@field buf integer|nil
---@field provider PullsProvider|nil
---@field requests AtlasRequestScope
---@field spinner_timer uv.uv_timer_t|nil
local M = {
	current_repo = nil,
	current_repo_details = nil,
	current_tab = nil,
	tabs = {},
	line_map = {},
	win = nil,
	buf = nil,
	provider = nil,
	requests = request_scope.new(),
	spinner_timer = nil,
}

function M.reset()
	M.current_repo = nil
	M.current_repo_details = nil
	M.current_tab = nil
	M.tabs = {}
	M.line_map = {}
	M.win = nil
	M.buf = nil
	M.provider = nil
	M.requests.cancel()
	M.requests = request_scope.new()
	M.spinner_timer = nil
end

return M
