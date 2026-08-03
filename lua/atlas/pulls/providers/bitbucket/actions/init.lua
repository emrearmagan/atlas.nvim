local M = {}

local registry = require("atlas.pulls.providers.bitbucket.actions.registry")
local logger = require("atlas.core.logger")
local statusline = require("atlas.ui.statusline")

---@alias BitbucketActionId
---| "merge"
---| "toggle_approval"
---| "request_changes"
---| "search"

---@param id BitbucketActionId|string
---@param ctx BitbucketActionContext
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
function M.run(id, ctx, on_done)
	local action = registry.find(id)

	if action == nil then
		local err = string.format("Unknown action: %s", tostring(id))
		logger.logerror("bitbucket.action.unknown", { action_id = tostring(id), source = ctx.source })
		on_done(nil, err)
		return
	end

	local available, available_err = action.is_available(ctx)
	if not available then
		local err = tostring(available_err or string.format("Action is not available: %s", tostring(id)))
		logger.logwarn("bitbucket.action.unavailable", { action_id = tostring(id), source = ctx.source, error = err })
		local notify = ctx.notify or statusline.notify
		notify("warn", err)
		on_done(nil, err)
		return
	end

	action.run(ctx, on_done)
end

---@param ctx BitbucketActionContext
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
function M.open(ctx, on_done)
	local actions = registry.available(ctx)
	if #actions == 0 then
		on_done({ changed_pr = false, message = "No actions available" }, nil)
		return
	end

	local pr_label = ""
	if ctx.pr ~= nil then
		pr_label = string.format(" PR #%s", tostring(ctx.pr.id or ""))
	end

	vim.ui.select(actions, {
		prompt = string.format("Choose Bitbucket action%s", pr_label),
		kind = "atlas_bitbucket_actions",
		format_item = function(item)
			return tostring((item and item.label) or "")
		end,
	}, function(action)
		if action == nil then
			on_done({ changed_pr = false, message = "Action cancelled" }, nil)
			return
		end

		action.run(ctx, on_done)
	end)
end

return M
