local M = {}

local utils = require("atlas.issues.actions.utils")

---@alias AtlasIssueActionId
---| "transition"
---| "assign"
---| "create_issue"
---| "search"
---| "browse_issue"
---| "copy_issue_key"
---| "copy_issue_url"
---| "toggle_subscription"

---@class AtlasIssueActionContext
---@field provider IssuesProvider
---@field issue Issue|nil
---@field current_user IssueUser|nil
---@field repo_slug string|nil
---@field project_path string|nil

---@class AtlasIssueAction
---@field id string
---@field label string
---@field hidden boolean|nil
---@field custom boolean|nil
---@field is_available (fun(context: AtlasIssueActionContext): boolean, string|nil)|nil
---@field run fun(context: AtlasIssueActionContext, on_done: fun(result: IssuesActionResult|nil, err: string|nil))

---@param id string
---@param context AtlasIssueActionContext
---@return boolean
function M.is_available(id, context)
	local actions = context.provider.capabilities.actions
	return actions ~= nil and actions.is_available(id, context)
end

---@param id string
---@param context AtlasIssueActionContext
---@param on_done fun(result: IssuesActionResult|nil, err: string|nil)|nil
---@return boolean handled
function M.run(id, context, on_done)
	local actions = context.provider.capabilities.actions
	if not actions then
		return false
	end
	return actions.run(id, context, on_done or function() end)
end

---@param context AtlasIssueActionContext
---@param on_done fun(result: IssuesActionResult|nil, err: string|nil)|nil
function M.open(context, on_done)
	local actions = context.provider.capabilities.actions
	local items = {}
	for _, action in ipairs(actions and actions.items or {}) do
		if not action.hidden and M.is_available(action.id, context) then
			table.insert(items, action)
		end
	end
	vim.list_extend(items, utils.custom_actions(context))
	if #items == 0 then
		if on_done then
			on_done(nil, "No actions available")
		end
		return
	end

	vim.ui.select(items, {
		prompt = string.format(
			"Choose %s action for %s",
			context.provider.name,
			tostring(context.issue and context.issue.key or "issue")
		),
		kind = "atlas_issue_actions",
		format_item = function(action)
			return action.label
		end,
	}, function(action)
		if not action then
			if on_done then
				on_done(nil, nil)
			end
			return
		end
		if action.custom then
			action.run(context, on_done or function() end)
			return
		end
		M.run(action.id, context, on_done)
	end)
end

M.browse_issue = utils.browse_issue
M.copy_issue_key = utils.copy_issue_key
M.copy_issue_url = utils.copy_issue_url

return M
