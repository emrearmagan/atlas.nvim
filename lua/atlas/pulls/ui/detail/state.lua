local request_scope = require("atlas.core.requests")

---@class PullsDetailState
---@field current_pr PullRequest|nil
---@field current_details PullRequestDetails|nil
---@field current_tab string|nil
---@field tabs PullsDetailTab[]
---@field line_map table<integer, table>
---@field diffstat PullsDiffstatEntry[]|"loading"|string|nil
---@field pipelines PullsPipeline[]|"loading"|string|nil
---@field pr_loading boolean
---@field details_loading boolean
---@field win integer|nil
---@field buf integer|nil
---@field provider PullsProvider|nil
---@field on_update fun(pr: PullRequest, result: PullsActionResult|nil)|nil
---@field requests AtlasRequestScope
---@field spinner_timer uv.uv_timer_t|nil
local M = {
	current_pr = nil,
	current_details = nil,
	current_tab = nil,
	tabs = {},
	line_map = {},
	diffstat = nil,
	pipelines = nil,
	pr_loading = false,
	details_loading = false,
	win = nil,
	buf = nil,
	provider = nil,
	on_update = nil,
	requests = request_scope.new(),
	spinner_timer = nil,
}

function M.reset()
	M.current_pr = nil
	M.current_details = nil
	M.current_tab = nil
	M.tabs = {}
	M.line_map = {}
	M.diffstat = nil
	M.pipelines = nil
	M.pr_loading = false
	M.details_loading = false
	M.win = nil
	M.buf = nil
	M.provider = nil
	M.on_update = nil
	M.requests.cancel()
	M.requests = request_scope.new()
	M.spinner_timer = nil
end

return M
