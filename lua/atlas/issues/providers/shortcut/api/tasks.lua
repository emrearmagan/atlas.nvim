local M = {}

local mapper = require("atlas.issues.providers.shortcut.api.mapper")
local service = require("atlas.issues.providers.shortcut.api.service")

---@param issue ShortcutIssue
local function invalidate(issue)
	service.clear_cache("story:" .. tostring(issue.id))
	service.clear_cache("search:")
end

---@param issue Issue
---@param description string
---@param on_done fun(task: ShortcutIssueTask|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create(issue, description, on_done)
	---@cast issue ShortcutIssue
	local endpoint = string.format("/stories/%d/tasks", issue.id)
	return service.request("POST", endpoint, { description = description }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		---@cast result table
		invalidate(issue)
		on_done(mapper.to_task(result), nil)
	end, {
		action = "Create Shortcut Story task",
		issue_key = issue.key,
	})
end

---@param issue Issue
---@param task ShortcutIssueTask
---@param fields { description?: string, complete?: boolean }
---@param on_done fun(task: ShortcutIssueTask|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.update(issue, task, fields, on_done)
	---@cast issue ShortcutIssue
	local endpoint = string.format("/stories/%d/tasks/%d", issue.id, task.id)
	return service.request("PUT", endpoint, fields, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		---@cast result table
		invalidate(issue)
		on_done(mapper.to_task(result), nil)
	end, {
		action = "Update Shortcut Story task",
		issue_key = issue.key,
	})
end

---@param issue Issue
---@param task ShortcutIssueTask
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete(issue, task, on_done)
	---@cast issue ShortcutIssue
	local endpoint = string.format("/stories/%d/tasks/%d", issue.id, task.id)
	return service.request("DELETE", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		invalidate(issue)
		on_done(true, nil)
	end, {
		action = "Delete Shortcut Story task",
		issue_key = issue.key,
	})
end

return M
