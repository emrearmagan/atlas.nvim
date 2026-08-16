local request_scope = require("atlas.core.requests")

---@class IssuesConversationTabState
---@field comments IssueComment[]|"loading"|nil
---@field activity IssueActivityEntry[]|"loading"|nil
---@field error string|nil
---@field generation integer
---@field collapsed table<string, boolean>
---@field expanded_runs table<string, boolean>
---@field requests AtlasRequestScope
local M = {
	comments = nil,
	activity = nil,
	error = nil,
	generation = 0,
	collapsed = {},
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

return M
