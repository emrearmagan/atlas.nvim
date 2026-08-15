local M = {}

local registry = require("atlas.issues.providers.jira.actions.registry")
local statusline = require("atlas.ui.statusline")

---@alias AtlasJiraIssueActionId
---| AtlasIssueActionId
---| "reporter"
---| "delete_issue"
---| "edit_issue"
---| "search_jql"

M.items = registry.items

---@param action_id AtlasJiraIssueActionId
---@param ctx AtlasIssueActionContext
---@return boolean
function M.is_available(action_id, ctx)
	local action = registry.find(action_id)
	return action ~= nil and (action.is_available == nil or action.is_available(ctx) == true)
end

---@param action_id AtlasJiraIssueActionId
---@param ctx AtlasIssueActionContext
---@param on_done fun(result: IssuesActionResult|nil, err: string|nil)
---@return boolean handled
function M.run(action_id, ctx, on_done)
	local action = registry.find(action_id)
	if action == nil then
		local err = string.format("Unknown action: %s", tostring(action_id))
		statusline.notify("warn", err)
		on_done(nil, err)
		return false
	end

	local available, err = true, nil
	if action.is_available then
		available, err = action.is_available(ctx)
	end
	if not available then
		err = tostring(err or "Action is not available")
		statusline.notify("warn", err)
		on_done(nil, err)
		return false
	end

	action.run(ctx, on_done)
	return true
end

return M
