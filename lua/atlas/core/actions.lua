local M = {}

local notify = require("atlas.core.notify")

---@param ctx AtlasActionContext
---@param on_done fun(result: AtlasActionResult|nil, err: string|nil)|nil
---@param err string
---@return false
function M.reject(ctx, on_done, err)
	if ctx.notify then
		ctx.notify("warn", err)
	else
		notify.warn(err)
	end
	if on_done then
		on_done(nil, err)
	end
	return false
end

---@param action AtlasAction|nil
---@param ctx AtlasActionContext
---@return boolean
function M.is_available(action, ctx)
	return action ~= nil and (action.is_available == nil or action.is_available(ctx) == true)
end

---@param action AtlasAction
---@param ctx AtlasActionContext
---@param on_done fun(result: AtlasActionResult|nil, err: string|nil)|nil
---@return boolean handled
function M.run(action, ctx, on_done)
	on_done = on_done or function() end
	if action.is_available then
		local available, reason = action.is_available(ctx)
		if not available then
			return M.reject(ctx, on_done, tostring(reason or string.format("Action is not available: %s", action.id)))
		end
	end
	return action.run(ctx, on_done) ~= false
end

return M
