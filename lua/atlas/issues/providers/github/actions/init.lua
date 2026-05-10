local M = {}

local registry = require("atlas.issues.providers.github.actions.registry")

---@param action_id string
---@param ctx table
---@param on_done fun(result: table|nil, err: string|nil)
function M.run(action_id, ctx, on_done)
	local action = registry.find(action_id)
	if action == nil then
		on_done(nil, string.format("Unknown action: %s", tostring(action_id)))
		return
	end

	local available, err = action.is_available(ctx)
	if not available then
		on_done(nil, tostring(err or "Action is not available"))
		return
	end

	action.run(ctx, on_done)
end

---@param ctx table
---@param on_done fun(result: table|nil, err: string|nil)
function M.open(ctx, on_done)
	local actions = registry.available(ctx)
	if #actions == 0 then
		on_done({ changed_issue_key = nil, message = "No actions available" }, nil)
		return
	end

	vim.ui.select(actions, {
		prompt = "Choose GitHub action",
		kind = "atlas_github_issue_actions",
		format_item = function(item)
			return tostring((item and item.label) or "")
		end,
	}, function(action)
		if action == nil then
			on_done({ changed_issue_key = nil, message = "Action cancelled" }, nil)
			return
		end
		action.run(ctx, on_done)
	end)
end

return M
