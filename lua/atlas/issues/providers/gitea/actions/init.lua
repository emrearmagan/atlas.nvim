local M = {}

local registry = require("atlas.issues.providers.gitea.actions.registry")
local statusline = require("atlas.ui.statusline")

---@alias AtlasGiteaIssueActionId
---| AtlasIssueActionId
---| "close"
---| "reopen"
---| "edit_issue"
---| "delete_issue"
---| "labels"
---| "milestone"
---| "pin"
---| "unpin"
---| "lock_issue"
---| "unlock_issue"

M.items = registry.items

---@param action_id AtlasGiteaIssueActionId
---@param ctx AtlasIssueActionContext
---@return boolean
function M.is_available(action_id, ctx)
	local action = registry.find(action_id)
	return action ~= nil and (action.is_available == nil or action.is_available(ctx) == true)
end

---@param action_id AtlasGiteaIssueActionId
---@param ctx AtlasIssueActionContext
---@param on_done fun(result: IssuesActionResult|nil, err: string|nil)
---@return boolean handled
function M.run(action_id, ctx, on_done)
	local action = registry.find(action_id)
	if not action then
		local err = string.format("Unknown action: %s", action_id)
		statusline.notify("warn", err)
		on_done(nil, err)
		return false
	end
	local available, err = true, nil
	if action.is_available then
		available, err = action.is_available(ctx)
	end
	if not available then
		err = err or "Action is not available"
		statusline.notify("warn", err)
		on_done(nil, err)
		return false
	end
	action.run(ctx, function(result, run_err)
		if run_err then
			statusline.notify("error", run_err)
		end
		on_done(result, run_err)
	end)
	return true
end

return M
