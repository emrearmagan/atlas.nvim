local M = {}

local registry = require("atlas.issues.providers.azure.actions.registry")
local notify = require("atlas.core.notify")

M.items = registry.items

---@param id string
---@param context AtlasIssueActionContext
---@return boolean
function M.is_available(id, context)
	local action = registry.find(id)
	return action ~= nil and (action.is_available == nil or action.is_available(context) == true)
end

---@param id string
---@param context AtlasIssueActionContext
---@param on_done fun(result: IssuesActionResult|nil, err: string|nil)
---@return boolean
function M.run(id, context, on_done)
	local action = registry.find(id)
	if not action then
		local err = "Unknown action: " .. id
		notify.warn(err)
		on_done(nil, err)
		return false
	end
	if action.is_available then
		local available, err = action.is_available(context)
		if not available then
			notify.warn(err)
			on_done(nil, err)
			return false
		end
	end
	action.run(context, on_done)
	return true
end

return M
