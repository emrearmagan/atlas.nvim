---@class PullsCommentsTabState
---@field comments PullsComment[]|"loading"|string|nil
---@field collapsed_hunks table<string, boolean>
---@field expanded_threads table<string, boolean>
local M = {
	comments = nil,
	collapsed_hunks = {},
	expanded_threads = {},
}

function M.reset()
	M.comments = nil
	M.collapsed_hunks = {}
	M.expanded_threads = {}
end

---@param root_id any
---@return boolean
function M.is_thread_expanded(root_id)
	return M.expanded_threads[tostring(root_id)] == true
end

---@param root_id any
function M.toggle_thread(root_id)
	local key = tostring(root_id)
	M.expanded_threads[key] = not M.expanded_threads[key]
end

---@return boolean
function M.any_loading()
	return M.comments == "loading"
end

return M
