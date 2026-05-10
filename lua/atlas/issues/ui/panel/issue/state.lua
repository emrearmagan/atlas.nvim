---@class IssuesPanelIssueState
---@field current_issue Issue|nil
---@field current_tab string|nil
---@field line_map table<integer, table>
local M = {
	current_issue = nil,
	current_tab = nil,
	line_map = {},
}

function M.reset()
	M.current_issue = nil
	M.current_tab = nil
	M.line_map = {}
end

return M
