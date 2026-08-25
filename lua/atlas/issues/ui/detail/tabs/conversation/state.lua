local request_scope = require("atlas.core.requests")
local utils = require("atlas.ui.shared.utils")

local MAX_COMMENT_LINES = 8

---@class IssuesConversationState
---@field items IssueConversationItem[]|"loading"|nil
---@field error string|nil
---@field collapsed table<string, boolean>
---@field expanded_comments table<string, boolean>
---@field expanded_runs table<string, boolean>
---@field requests AtlasRequestScope
---@field current_issue Issue|nil
local M = {
	items = nil,
	error = nil,
	collapsed = {},
	expanded_comments = {},
	expanded_runs = {},
	requests = request_scope.new(),
	current_issue = nil,
}

function M.reset()
	M.current_issue = nil
	M.requests.cancel()
	M.requests = request_scope.new()
	M.items = nil
	M.error = nil
	M.collapsed = {}
	M.expanded_comments = {}
	M.expanded_runs = {}
end

---@param issue Issue
function M.activate(issue)
	M.reset()
	M.current_issue = issue
end

function M.deactivate()
	M.current_issue = nil
	M.requests.cancel()
	M.requests = request_scope.new()
end

---@param issue Issue
---@return boolean
function M.is_current(issue)
	return M.current_issue ~= nil and tostring(M.current_issue.key or "") == tostring(issue.key or "")
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
function M.is_loading()
	return M.items == "loading"
end

---@return IssueComment[]
function M.comments()
	local result = {}
	if type(M.items) ~= "table" then
		return result
	end
	for _, item in ipairs(M.items) do
		if item.kind == "comment" then
			---@type IssueComment
			local comment = item.entity
			table.insert(result, comment)
		end
	end
	return result
end

---@param comment IssueComment
function M.upsert_comment(comment)
	if type(M.items) ~= "table" then
		return
	end
	local id = "comment:" .. tostring(comment.id)
	local item = { id = id, kind = "comment", created_at = comment.created or "", entity = comment }
	for index, current in ipairs(M.items) do
		if current.id == id then
			M.items[index] = item
			return
		end
	end
	table.insert(M.items, item)
end

---@param comment IssueComment
function M.remove_comment(comment)
	if type(M.items) ~= "table" then
		return
	end
	for _, item in ipairs(M.items) do
		if item.kind == "comment" then
			---@type IssueComment
			local current = item.entity
			if tostring(current.parent_id or "") == tostring(comment.id) then
				comment.body = nil
				comment.deleted = true
				return
			end
		end
	end
	local id = "comment:" .. tostring(comment.id)
	for index = #M.items, 1, -1 do
		if M.items[index].id == id then
			table.remove(M.items, index)
			return
		end
	end
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
