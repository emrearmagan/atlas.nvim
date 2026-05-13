---@class PullsState
---@field active_view AtlasPullsViewConfig|nil
---@field current_view AtlasPullsViewConfig|nil
---@field is_loading boolean
---@field error string|nil
---@field current_user PullsUser|nil
---@field pulls PullsGroup[]|nil
---@field provider PullsProvider|nil
---@field latest_request_tokens table
---@field request_seq number
---@field reloading_pr_keys table<string, integer>
---@field reload_spinner_frame string
---@field status_filters table<string, boolean>
---@field last_search_query string|nil
local M = {
	active_view = nil,
	current_view = nil,
	is_loading = false,
	error = nil,
	current_user = nil,
	pulls = nil,
	provider = nil,
	latest_request_tokens = {},
	request_seq = 0,
	reloading_pr_keys = {},
	reload_spinner_frame = "⠋",
	status_filters = { OPEN = true, MERGED = false, DECLINED = false },
	last_search_query = nil,
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

function M.reset()
	M.active_view = nil
	M.current_view = nil
	M.is_loading = false
	M.error = nil
	M.current_user = nil
	M.pulls = nil
	M.provider = nil
	M.latest_request_tokens = {}
	M.request_seq = 0
	M.reloading_pr_keys = {}
	M.reload_spinner_frame = "⠋"
	M.status_filters = { OPEN = true, MERGED = false, DECLINED = false }
	M.last_search_query = nil
end

return M
