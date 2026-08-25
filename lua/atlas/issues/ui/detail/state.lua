local request_scope = require("atlas.core.requests")

---@class IssuesDetailState
---@field win integer|nil
---@field buf integer|nil
---@field provider IssuesProvider|nil
---@field provider_detail IssuesProviderDetail|nil
---@field current_issue Issue|nil
---@field current_details IssueDetails|nil
---@field current_tab string|nil
---@field tabs IssuesDetailTabDefinition[]
---@field on_update fun(issue: Issue|nil, result: IssuesActionResult|nil)|nil
---@field line_map table<integer, table>
---@field details_loading boolean
---@field issue_loading boolean
---@field requests AtlasRequestScope
---@field spinner_timer uv.uv_timer_t|nil
local M = {
	win = nil,
	buf = nil,
	provider = nil,
	provider_detail = nil,
	current_issue = nil,
	current_details = nil,
	current_tab = nil,
	tabs = {},
	on_update = nil,
	line_map = {},
	details_loading = false,
	issue_loading = false,
	requests = request_scope.new(),
	spinner_timer = nil,
}

function M.reset()
	M.win = nil
	M.buf = nil
	M.provider = nil
	M.provider_detail = nil
	M.current_issue = nil
	M.current_details = nil
	M.current_tab = nil
	M.tabs = {}
	M.on_update = nil
	M.line_map = {}
	M.details_loading = false
	M.issue_loading = false
	M.requests.cancel()
	M.requests = request_scope.new()
	M.spinner_timer = nil
end

return M
