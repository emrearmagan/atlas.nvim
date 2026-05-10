---@class GitLabPullsProviderPanel : PullsProviderPanel
local M = {}

---@param _pr PullRequest
---@param active_tab string|nil
---@return boolean
function M.is_loading(_pr, active_tab)
	if active_tab ~= nil and active_tab ~= "overview" then
		return false
	end

	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	return overview_state.any_loading()
end

return M
