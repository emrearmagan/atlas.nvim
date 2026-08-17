local request_scope = require("atlas.core.requests")
local utils = require("atlas.ui.shared.utils")

local MAX_COMMENT_LINES = 8

---@class PullsConversationTabState
---@field comments PullsComment[]|"loading"|nil
---@field tasks PullsComment[]|"loading"|nil
---@field activity PullsActivityEntry[]|"loading"|nil
---@field error string|nil
---@field generation integer
---@field collapsed table<string, boolean>
---@field expanded_comments table<string, boolean>
---@field expanded_runs table<string, boolean>
---@field requests AtlasRequestScope
local M = {
	comments = nil,
	tasks = nil,
	activity = nil,
	error = nil,
	generation = 0,
	collapsed = {},
	expanded_comments = {},
	expanded_runs = {},
	requests = request_scope.new(),
}

local current_pr = nil

function M.reset()
	M.generation = M.generation + 1
	current_pr = nil
	M.requests.cancel()
	M.requests = request_scope.new()
	M.comments = nil
	M.tasks = nil
	M.activity = nil
	M.error = nil
	M.collapsed = {}
	M.expanded_comments = {}
	M.expanded_runs = {}
end

---@param pr PullRequest
---@return integer
function M.activate(pr)
	M.reset()
	current_pr = pr
	return M.generation
end

function M.deactivate()
	M.generation = M.generation + 1
	current_pr = nil
	M.requests.cancel()
	M.requests = request_scope.new()
end

---@param expected_generation integer
---@param pr PullRequest
---@return boolean
function M.is_current(expected_generation, pr)
	return M.generation == expected_generation and current_pr == pr
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
	return M.comments == "loading" or M.tasks == "loading" or M.activity == "loading"
end

---@param comment PullsComment
---@return string
local function comment_key(comment)
	return (comment.is_task and "task:" or "comment:") .. tostring(comment.id)
end

---@param comment PullsComment
---@return boolean
function M.is_comment_long(comment)
	if comment.is_task or comment.state == "DELETED" then
		return false
	end
	local content = utils.strip_markup(comment.content_display or comment.content_raw or "")
	local lines = utils.sanitize_lines(content)
	while #lines > 0 and vim.trim(lines[#lines]) == "" do
		table.remove(lines)
	end
	return #lines > MAX_COMMENT_LINES
end

---@param comment PullsComment
---@return boolean
function M.is_comment_expanded(comment)
	return M.expanded_comments[comment_key(comment)] == true
end

---@param comment PullsComment
---@return integer|nil
function M.comment_max_lines(comment)
	if M.is_comment_long(comment) and not M.is_comment_expanded(comment) then
		return MAX_COMMENT_LINES
	end
	return nil
end

---@param comment PullsComment
---@return boolean toggled
function M.toggle_comment(comment)
	if not M.is_comment_long(comment) then
		return false
	end
	local key = comment_key(comment)
	M.expanded_comments[key] = not M.expanded_comments[key]
	return true
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

---@param threads AtlasReviewThreadNode[]
---@return boolean
function M.toggle_all_threads(threads)
	local roots = {}
	local expand = false
	for _, thread in ipairs(threads) do
		if not thread.comment.is_task and #thread.children > 0 then
			table.insert(roots, thread.comment)
			if M.is_collapsed(thread.comment.id) then
				expand = true
			end
		end
	end
	for _, root in ipairs(roots) do
		M.collapsed[tostring(root.id)] = not expand
	end
	return #roots > 0
end

return M
