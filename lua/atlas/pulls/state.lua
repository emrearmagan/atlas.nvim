---@class PullsState
---@field active_view AtlasPullsViewConfig|nil
---@field current_view AtlasPullsViewConfig|nil
---@field is_loading boolean
---@field error string|nil
---@field current_user PullsUser|nil
---@field pulls PullRequest[]|nil
---@field provider PullsProvider|nil
---@field reloading_pr_keys table<string, integer>
---@field reload_spinner_frame string
---@field status_filters table<string, boolean>
local M = {
	active_view = nil,
	current_view = nil,
	is_loading = false,
	error = nil,
	current_user = nil,
	pulls = nil,
	provider = nil,
	reloading_pr_keys = {},
	reload_spinner_frame = "⠋",
	status_filters = { OPEN = true, MERGED = false, DECLINED = false },
}

---@param repo_id string
---@param pr_id string|number
---@return string
function M.reload_key(repo_id, pr_id)
	return tostring(repo_id) .. ":" .. tostring(pr_id)
end

---@param repo_id string
---@param pr_id string|number
---@return boolean
function M.is_pr_reloading(repo_id, pr_id)
	local key = M.reload_key(repo_id, pr_id)
	return (tonumber(M.reloading_pr_keys[key]) or 0) > 0
end

return M
