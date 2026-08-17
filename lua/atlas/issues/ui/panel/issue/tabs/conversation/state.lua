local request_scope = require("atlas.core.requests")
local utils = require("atlas.ui.shared.utils")

local MAX_COMMENT_LINES = 8

---@class IssuesConversationTabState
---@field comments IssueComment[]|"loading"|nil
---@field activity IssueActivityEntry[]|"loading"|nil
---@field error string|nil
---@field generation integer
---@field collapsed table<string, boolean>
---@field expanded_comments table<string, boolean>
---@field expanded_runs table<string, boolean>
---@field requests AtlasRequestScope
local M = {
	comments = nil,
	activity = nil,
	error = nil,
	generation = 0,
	collapsed = {},
	expanded_comments = {},
	expanded_runs = {},
	requests = request_scope.new(),
}

local current_issue = nil

function M.reset()
	M.generation = M.generation + 1
	current_issue = nil
	M.requests.cancel()
	M.requests = request_scope.new()
	M.comments = nil
	M.activity = nil
	M.error = nil
	M.collapsed = {}
	M.expanded_comments = {}
	M.expanded_runs = {}
end

---@param issue Issue
---@return integer
function M.activate(issue)
	M.reset()
	current_issue = issue
	return M.generation
end

function M.deactivate()
	M.generation = M.generation + 1
	current_issue = nil
	M.requests.cancel()
	M.requests = request_scope.new()
end

---@param generation integer
---@param issue Issue
---@return boolean
function M.is_current(generation, issue)
	return M.generation == generation and current_issue == issue
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

---@param comment IssueComment
---@return boolean
local function is_comment_long(comment)
	if comment.deleted then
		return false
	end
	local lines = utils.sanitize_lines(utils.strip_markup(comment.body or ""))
	while #lines > 0 and vim.trim(lines[#lines]) == "" do
		table.remove(lines)
	end
	return #lines > MAX_COMMENT_LINES
end

---@param comment IssueComment
---@return integer|nil
function M.comment_max_lines(comment)
	if is_comment_long(comment) and M.expanded_comments[tostring(comment.id)] ~= true then
		return MAX_COMMENT_LINES
	end
end

---@param comment IssueComment
---@return boolean
function M.toggle_comment(comment)
	if not is_comment_long(comment) then
		return false
	end
	local key = tostring(comment.id)
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

---@param threads IssuesCommentThreadNode[]
---@return boolean
function M.toggle_all_threads(threads)
	local roots = {}
	local expand = false
	for _, thread in ipairs(threads) do
		if #thread.children > 0 then
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
