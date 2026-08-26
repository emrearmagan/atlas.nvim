local M = {}

local registry = require("atlas.pulls.providers.azure.actions.registry")
local logger = require("atlas.core.logger")
local core_notify = require("atlas.core.notify")

M.items = registry.items

---@param id AtlasPullActionId
---@param ctx AtlasPullActionContext
---@return boolean
function M.is_available(id, ctx)
	local action = registry.find(id)
	return action ~= nil and (action.is_available == nil or action.is_available(ctx) == true)
end

---@param id AtlasPullActionId
---@param ctx AtlasPullActionContext
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
---@return boolean handled
function M.run(id, ctx, on_done)
	local action = registry.find(id)
	if action == nil then
		local err = string.format("Unknown action: %s", id)
		logger.logerror("azure.action.unknown", { action_id = id })
		on_done(nil, err)
		return false
	end

	if action.is_available then
		local available, available_err = action.is_available(ctx)
		if not available then
			local err = available_err or string.format("Action is not available: %s", id)
			if ctx.notify then
				ctx.notify("warn", err)
			else
				core_notify.warn(err)
			end
			on_done(nil, err)
			return false
		end
	end

	action.run(ctx, on_done)
	return true
end

return M
