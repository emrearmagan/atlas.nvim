---@class PullsConversationTabState
---@field comments PullsComment[]|"loading"|string|nil
---@field activity PullsActivityEntry[]|"loading"|string|nil
---@field collapsed table<string, boolean>
---@field expanded_runs table<string, boolean>
---@field reaction_options PullsReactionOption[]
local M = {
	comments = nil,
	activity = nil,
	collapsed = {},
	expanded_runs = {},
	reaction_options = {},
}

function M.reset()
	M.comments = nil
	M.activity = nil
	M.collapsed = {}
	M.expanded_runs = {}
	M.reaction_options = {}
end

---@param run_id any
function M.toggle_run(run_id)
	local key = tostring(run_id)
	M.expanded_runs[key] = not M.expanded_runs[key]
end

---@param run_id any
---@return boolean
function M.is_run_expanded(run_id)
	return M.expanded_runs[tostring(run_id)] == true
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
