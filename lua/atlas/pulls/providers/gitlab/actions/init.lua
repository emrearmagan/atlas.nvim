local M = {}

local registry = require("atlas.pulls.providers.gitlab.actions.registry")
local logger = require("atlas.core.logger")
local footer = require("atlas.ui.components.footer")

---@class GitLabPullsActionContext
---@field pr PullRequest|nil
---@field source "main"|"panel"|nil

---@param id string
---@param ctx GitLabPullsActionContext
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
function M.run(id, ctx, on_done)
	local action = registry.find(id)
	if action == nil then
		local err = string.format("Unknown action: %s", tostring(id))
		logger.logerror("gitlab.pulls.action.unknown", { action_id = tostring(id), source = ctx and ctx.source or nil })
		on_done(nil, err)
		return
	end

	local available, available_err = action.is_available(ctx)
	if not available then
		local err = tostring(available_err or string.format("Action is not available: %s", tostring(id)))
		footer.notify("warn", err)
		on_done(nil, err)
		return
	end

	action.run(ctx, on_done)
end

---@param ctx GitLabPullsActionContext
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
function M.open(ctx, on_done)
	local actions = registry.available(ctx)
	if #actions == 0 then
		on_done({ changed_pr = false, message = "No actions available" }, nil)
		return
	end

	local pr_label = ""
	if ctx and ctx.pr ~= nil then
		pr_label = string.format(" MR !%s", tostring(ctx.pr.id or ""))
	end

	vim.ui.select(actions, {
		prompt = string.format("Choose GitLab action%s", pr_label),
		kind = "atlas_gitlab_pulls_actions",
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
