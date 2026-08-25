---@class PullsState
---@field active_view AtlasPullsViewConfig|nil
---@field current_view AtlasPullsViewConfig|nil
---@field views AtlasPullsViewConfig[]
---@field is_loading boolean
---@field error string|nil
---@field current_user PullsUser|nil
---@field pulls PullRequest[]
---@field provider PullsProvider|nil
---@field provider_views AtlasPullsViewConfig[]
---@field starred_items AtlasStarredItem[]
---@field reloading_pr_keys table<string, boolean>
---@field reload_spinner_frame string
---@field status_filters table<string, boolean>
local M = {
	active_view = nil,
	current_view = nil,
	views = {},
	is_loading = false,
	error = nil,
	current_user = nil,
	pulls = {},
	provider = nil,
	provider_views = {},
	starred_items = {},
	reloading_pr_keys = {},
	reload_spinner_frame = "⠋",
	status_filters = { OPEN = true, MERGED = false, DECLINED = false },
}

---@param repo_id string
---@param pr_id string|number
---@return boolean
function M.is_pr_reloading(repo_id, pr_id)
	return M.reloading_pr_keys[repo_id .. ":" .. tostring(pr_id)] == true
end

return M
