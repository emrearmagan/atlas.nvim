---@class PullsConversationTabState
---@field comments PullsComment[]|"loading"|string|nil
---@field activity PullsActivityEntry[]|"loading"|string|nil
---@field collapsed table<string, boolean>
---@field reaction_options PullsReactionOption[]
local M = {
	comments = nil,
	activity = nil,
	collapsed = {},
	reaction_options = {},
}

function M.reset()
	M.comments = nil
	M.activity = nil
	M.collapsed = {}
	M.reaction_options = {}
end

---@return boolean
function M.any_loading()
	return M.comments == "loading" or M.activity == "loading"
end

---@param root_id any
---@return boolean
function M.is_collapsed(root_id)
	return M.collapsed[tostring(root_id)] == true
end

---@param root_id any
function M.toggle(root_id)
	local key = tostring(root_id)
	M.collapsed[key] = not M.collapsed[key]
end

return M
