---@class PullsCommentsTabState
---@field comments PullsComment[]|"loading"|string|nil
---@field tasks PullsComment[]|"loading"|string|nil
---@field collapsed_hunks table<string, boolean>
---@field expanded_threads table<string, boolean>
local M = {
	comments = nil,
	tasks = nil,
	collapsed_hunks = {},
	expanded_threads = {},
}

function M.reset()
	M.comments = nil
	M.tasks = nil
	M.collapsed_hunks = {}
	M.expanded_threads = {}
end

---@param root PullsComment
---@return boolean
function M.is_thread_expanded(root)
	local value = M.expanded_threads[tostring(root.id)]
	if value ~= nil then
		return value
	end
	return root.state ~= "RESOLVED" and root.state ~= "OUTDATED"
end

---@param root PullsComment
---@param expanded boolean
local function set_expanded(root, expanded)
	local default = root.state ~= "RESOLVED" and root.state ~= "OUTDATED"
	M.expanded_threads[tostring(root.id)] = expanded == default and nil or expanded
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
---@param hunk_keys string[]
---@return boolean
function M.toggle_all_folds(comments, hunk_keys)
	local roots = thread_roots(comments)
	if #roots == 0 and #hunk_keys == 0 then
		return false
	end

	local collapse = false
	for _, root in ipairs(roots) do
		if M.is_thread_expanded(root) then
			collapse = true
			break
		end
	end
	if not collapse then
		for _, key in ipairs(hunk_keys) do
			if M.collapsed_hunks[key] ~= true then
				collapse = true
				break
			end
		end
	end

	for _, root in ipairs(roots) do
		set_expanded(root, not collapse)
	end
	for _, key in ipairs(hunk_keys) do
		M.collapsed_hunks[key] = collapse
	end
	return true
end

---@return boolean
function M.any_loading()
	return M.comments == "loading" or M.tasks == "loading"
end

return M
