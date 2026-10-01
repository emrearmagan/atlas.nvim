local request_scope = require("atlas.core.requests")
local review_actions = require("atlas.pulls.actions.review")

---@class PullsReviewState
---@field data PullsReviewData|nil
---@field status string|nil
---@field expanded_threads table<string, boolean>
---@field requests AtlasRequestScope
---@field current_pr PullRequest|nil
local M = {
	data = nil,
	status = nil,
	expanded_threads = {},
	requests = request_scope.new(),
	current_pr = nil,
}

function M.reset()
	M.data = nil
	M.status = nil
	M.expanded_threads = {}
	M.requests.cancel()
	M.requests = request_scope.new()
	M.current_pr = nil
end

---@param root PullsComment
---@return boolean
function M.is_thread_expanded(root)
	local expanded = M.expanded_threads[tostring(root.id)]
	if expanded ~= nil then
		return expanded
	end
	return root.state ~= "RESOLVED"
end

---@param root PullsComment
---@param expanded boolean
local function set_expanded(root, expanded)
	M.expanded_threads[tostring(root.id)] = expanded
end

---@param roots PullsComment[]
---@return boolean
function M.toggle_threads(roots)
	if #roots == 0 then
		return false
	end
	local expand = false
	for _, root in ipairs(roots) do
		if not M.is_thread_expanded(root) then
			expand = true
			break
		end
	end
	for _, root in ipairs(roots) do
		set_expanded(root, expand)
	end
	return true
end

---@param comments PullsComment[]
---@return boolean
function M.toggle_all_folds(comments)
	local roots = {}
	for _, node in ipairs(review_actions.group_comments(comments)) do
		table.insert(roots, node.comment)
	end
	return M.toggle_threads(roots)
end

return M
