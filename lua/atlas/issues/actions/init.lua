local M = {}

local action_runner = require("atlas.core.actions")
local icons = require("atlas.ui.shared.icons")
local picker = require("atlas.ui.picker")
local providers = require("atlas.providers")
local repository = require("atlas.ui.repository")
local templates = require("atlas.issues.templates")
local utils = require("atlas.issues.actions.utils")

---@alias AtlasIssueActionId
---| "transition"
---| "assign"
---| "create_issue"
---| "edit_issue"
---| "search"
---| "edit_search"
---| "browse_issue"
---| "browse_repository"
---| "browse_repositories"
---| "copy_issue_key"
---| "copy_issue_url"
---| "manage_templates"
---| "toggle_subscription"

---@class AtlasIssueActionContext
---@field provider IssuesProvider
---@field issue Issue|nil
---@field current_user AtlasUser|nil
---@field repo_slug string|nil
---@field project_path string|nil
---@field notify fun(level: AtlasNotifyLevel, message: string, duration: integer|nil)|nil

---@class AtlasIssueAction
---@field id string
---@field label string
---@field icon string|nil
---@field hidden boolean|nil
---@field is_available (fun(context: AtlasIssueActionContext): boolean, string|nil)|nil
---@field run fun(context: AtlasIssueActionContext, on_done: fun(result: IssuesActionResult|nil, err: string|nil)): boolean|{ cancel: fun() }|nil

---@param id string
---@param context AtlasIssueActionContext
---@return AtlasIssueAction|nil
function M.find(id, context)
	local action = utils.find_custom_action(id)
	if action then
		return action
	end
	local actions = context.provider.capabilities.actions
	local provider_action = actions and actions.find(id) or nil
	---@cast provider_action AtlasIssueAction|nil
	return provider_action
end

---@param id string
---@param context AtlasIssueActionContext
---@return boolean
function M.is_available(id, context)
	return action_runner.is_available(M.find(id, context), context)
end

---@param id string
---@param context AtlasIssueActionContext
---@param on_done fun(result: IssuesActionResult|nil, err: string|nil)|nil
---@return boolean handled
function M.run(id, context, on_done)
	local action = M.find(id, context)
	if action then
		return action_runner.run(action, context, on_done)
	end
	if not context.provider.capabilities.actions then
		return false
	end
	return action_runner.reject(context, on_done, string.format("Unknown action: %s", tostring(id)))
end

---@param context AtlasIssueActionContext
---@param on_done fun(result: IssuesActionResult|nil, err: string|nil)|nil
---@param extra_items { label: string, icon?: string, callback: fun() }[]|nil
function M.open(context, on_done, extra_items)
	local actions = context.provider.capabilities.actions
	local items = {}
	for _, action in ipairs(actions and actions.items or {}) do
		if not action.hidden and not utils.find_custom_action(action.id) and M.is_available(action.id, context) then
			table.insert(items, action)
		end
	end
	for _, action in ipairs(utils.custom_actions()) do
		if action_runner.is_available(action, context) then
			table.insert(items, action)
		end
	end
	vim.list_extend(items, extra_items or {})
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
			if action.callback then
				action.callback()
			else
				M.run(action.id, context, on_done)
			end
		end,
	})
end

M.browse_repository = {
	id = "browse_repository",
	label = "Browse Current Repository",
	icon = icons.general("overview"),
	is_available = function(context)
		return context.issue ~= nil and context.issue.url ~= nil
	end,
	run = function(context, done)
		local issue = assert(context.issue)
		local target, err = providers.resolve(assert(issue.url))
		if not target or not target.repo_full_name then
			done(nil, err or "Missing repository info")
			return
		end
		repository.open(target.repo_full_name, context.provider)
		done(nil, nil)
	end,
}

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
