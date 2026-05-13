---@class PullsCommentsTabState
---@field comments PullsComment[]|"loading"|string|nil
---@field collapsed_hunks table<string, boolean>
local M = {
	comments = nil,
	collapsed_hunks = {},
}

function M.reset()
	M.comments = nil
	M.collapsed_hunks = {}
end

---@return boolean
function M.any_loading()
	return M.comments == "loading"
end

return M
