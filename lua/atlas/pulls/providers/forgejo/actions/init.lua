local M = {}

local logger = require("atlas.core.logger")
local registry = require("atlas.pulls.providers.forgejo.actions.registry")
local notify = require("atlas.core.notify")

---@alias AtlasForgejoActionId
---| AtlasPullActionId
---| "reopen"
---| "update_branch"
---| "edit_assignees"
---| "labels"
---| "search_pull_requests"
---| "toggle_subscription"

M.items = registry.items

---@param id AtlasForgejoActionId
---@return AtlasPullAction|nil
local function find(id)
	return registry.find(id)
end

---@param id AtlasForgejoActionId
---@param ctx AtlasPullActionContext
---@return boolean
function M.is_available(id, ctx)
	local action = find(id)
	return action ~= nil and (action.is_available == nil or action.is_available(ctx) == true)
end

---@param id AtlasForgejoActionId
---@param ctx AtlasPullActionContext
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
---@return boolean handled
function M.run(id, ctx, on_done)
	local action = find(id)
	if action == nil then
		local err = string.format("Unknown action: %s", tostring(id))
		logger.logerror("forgejo.pulls.action.unknown", { action_id = tostring(id) })
		on_done(nil, err)
		return false
	end

	local available, available_err = true, nil
	if action.is_available then
		available, available_err = action.is_available(ctx)
	end
	if not available then
		local err = tostring(available_err or string.format("Action is not available: %s", tostring(id)))
		logger.logwarn("forgejo.pulls.action.unavailable", { action_id = tostring(id), error = err })
		if ctx.notify then
			ctx.notify("warn", err)
		else
			notify.warn(err)
		end
		on_done(nil, err)
		return false
	end

	action.run(ctx, on_done)
	return true
end

return M
