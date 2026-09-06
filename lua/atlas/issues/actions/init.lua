local M = {}

local icons = require("atlas.ui.shared.icons")
local picker = require("atlas.ui.picker")
local templates = require("atlas.issues.templates")
local utils = require("atlas.issues.actions.utils")

---@alias AtlasIssueActionId
---| "transition"
---| "assign"
---| "create_issue"
---| "search"
---| "edit_search"
---| "browse_issue"
---| "copy_issue_key"
---| "copy_issue_url"
---| "manage_templates"
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
---@field icon string|nil
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

	local target = context.issue and string.format(" for %s", tostring(context.issue.key)) or ""
	picker.select({
		title = string.format("Choose %s action%s", context.provider.name, target),
		items = items,
		format_item = icons.format_action,
		on_select = function(action)
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
		end,
	})
end

M.browse_issue = utils.browse_issue
M.copy_issue_key = utils.copy_issue_key
M.copy_issue_url = utils.copy_issue_url
M.manage_templates = {
	id = "manage_templates",
	label = "Manage Issue Templates",
	icon = icons.action("edit"),
	run = function(_, done)
		templates.manage(function(err)
			done(nil, err)
		end)
	end,
}

return M
