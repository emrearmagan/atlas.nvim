---@class GHIssuesConversationState
---@field issue Issue|nil
---@field comments IssueComment[]|"loading"|string|nil
---@field timeline GHIssueTimelineEntry[]|"loading"|string|nil
local M = {
	issue = nil,
	comments = nil,
	timeline = nil,
}

function M.reset()
	M.issue = nil
	M.comments = nil
	M.timeline = nil
end

---@return boolean
function M.any_loading()
	return M.comments == "loading" or M.timeline == "loading"
end

return M
