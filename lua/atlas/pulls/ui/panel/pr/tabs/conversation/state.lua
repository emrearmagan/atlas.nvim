local request_scope = require("atlas.core.requests")

---@class PullsConversationTabState
---@field comments PullsComment[]|"loading"|nil
---@field activity PullsActivityEntry[]|"loading"|nil
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

local current_pr = nil

function M.reset()
	M.generation = M.generation + 1
	current_pr = nil
	M.requests.cancel()
	M.requests = request_scope.new()
	M.comments = nil
	M.activity = nil
	M.error = nil
	M.collapsed = {}
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
