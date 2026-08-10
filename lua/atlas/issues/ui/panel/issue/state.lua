---@class IssuesPanelIssueState
---@field current_issue Issue|nil
---@field current_tab string|nil
---@field line_map table<integer, table>
---@field header_loading boolean
local M = {
	current_issue = nil,
	current_tab = nil,
	line_map = {},
	header_loading = false,
}

function M.reset()
	M.current_issue = nil
	M.current_tab = nil
	M.line_map = {}
	M.header_loading = false
end

return M
