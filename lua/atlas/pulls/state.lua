---@class PullsState
---@field available_states PullsStateFilter[]
---@field view AtlasPullsViewConfig|nil
---@field views AtlasPullsViewConfig[]
---@field bookmarks AtlasBookmarksState|nil
---@field query string
---@field is_loading boolean
---@field error string|nil
---@field current_user PullsUser|nil
---@field pulls PullRequest[]
---@field provider PullsProvider|nil
---@field provider_views AtlasPullsViewConfig[]
---@field starred_items AtlasStarredItem[]
---@field reloading_pr_keys table<string, boolean>
---@field reload_spinner_frame string
local M = {
	available_states = { "open", "merged", "declined" },
	view = nil,
	views = {},
	bookmarks = nil,
	query = "",
	is_loading = false,
	error = nil,
	current_user = nil,
	pulls = {},
	provider = nil,
	provider_views = {},
	starred_items = {},
	reloading_pr_keys = {},
	reload_spinner_frame = "⠋",
}

---@return AtlasPullsViewConfig|nil
function M.search_view()
	local bookmarks = M.bookmarks
	if bookmarks ~= nil and M.view == bookmarks.tab then
		local selection = bookmarks.selection
		return selection and selection.kind == "bookmark" and selection.view or nil
	end
	return M.view
end

---@return PullsStateFilter[]
function M.selected_states()
	local view = M.search_view()
	return (view and view._states) or {}
end

---@param repo_id string
---@param pr_id string|number
---@return boolean
function M.is_pr_reloading(repo_id, pr_id)
	return M.reloading_pr_keys[repo_id .. ":" .. tostring(pr_id)] == true
end

return M
