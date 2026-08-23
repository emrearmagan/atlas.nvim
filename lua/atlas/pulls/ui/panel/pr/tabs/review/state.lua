---@class PullsReviewTabState
---@field data PullsReviewData|nil
---@field status string|nil
---@field hunks_by_comment table<string, { hunk: DiffHunk, anchor: integer }>
---@field expanded_threads table<string, boolean>
local M = {
	data = nil,
	status = nil,
	hunks_by_comment = {},
	expanded_threads = {},
}

function M.reset()
	M.data = nil
	M.status = nil
	M.hunks_by_comment = {}
	M.expanded_threads = {}
end

---@param root PullsComment
---@return boolean
function M.is_thread_expanded(root)
	return M.expanded_threads[tostring(root.id)] == true
end

---@param root PullsComment
---@param expanded boolean
local function set_expanded(root, expanded)
	M.expanded_threads[tostring(root.id)] = expanded and true or nil
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
---@return PullsComment[]
local function thread_roots(comments)
	local ids = {}
	for _, comment in ipairs(comments) do
		ids[tostring(comment.id)] = true
	end
	local roots = {}
	for _, comment in ipairs(comments) do
		if comment.parent_id == nil or not ids[tostring(comment.parent_id)] then
			table.insert(roots, comment)
		end
	end
	return roots
end

---@param comments PullsComment[]
---@return boolean
function M.toggle_all_folds(comments)
	local roots = thread_roots(comments)
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

---@return boolean
function M.any_loading()
	return M.status == "loading"
end

return M
