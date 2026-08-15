local M = {}

local registry = require("atlas.pulls.providers.bitbucket.actions.registry")
local logger = require("atlas.core.logger")
local statusline = require("atlas.ui.statusline")

M.items = registry.items

---@param id AtlasPullActionId
---@return AtlasPullAction|nil
local function find(id)
	return registry.find(id)
end

---@param id AtlasPullActionId
---@param ctx AtlasPullActionContext
---@return boolean
function M.is_available(id, ctx)
	local action = find(id)
	return action ~= nil and (action.is_available == nil or action.is_available(ctx) == true)
end

---@param id AtlasPullActionId
---@param ctx AtlasPullActionContext
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
---@return boolean handled
function M.run(id, ctx, on_done)
	local action = find(id)

	if action == nil then
		local err = string.format("Unknown action: %s", tostring(id))
		logger.logerror("bitbucket.action.unknown", { action_id = tostring(id) })
		on_done(nil, err)
		return false
	end

	local available, available_err = true, nil
	if action.is_available then
		available, available_err = action.is_available(ctx)
	end
	if not available then
		local err = tostring(available_err or string.format("Action is not available: %s", tostring(id)))
		logger.logwarn("bitbucket.action.unavailable", { action_id = tostring(id), error = err })
		local notify = ctx.notify or statusline.notify
		notify("warn", err)
		on_done(nil, err)
		return false
	end

	action.run(ctx, on_done)
	return true
end

return M
