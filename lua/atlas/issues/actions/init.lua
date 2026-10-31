local M = {}

local action_runner = require("atlas.core.actions")
local icons = require("atlas.ui.shared.icons")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")
local repository = require("atlas.ui.repository")
local templates = require("atlas.templates")
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

---@class IssuesActionResult
---@field issue_key string|nil
---@field removed boolean|nil

---@class AtlasIssueActionContext
---@field provider IssuesProvider
---@field issue Issue|nil
---@field current_user AtlasUser|nil
---@field repo_slug string|nil
---@field project_path string|nil

---@class AtlasIssueAction: AtlasAction
---@field is_available (fun(context: AtlasIssueActionContext): boolean, string|nil)|nil
---@field run fun(context: AtlasIssueActionContext, on_done: fun(result: IssuesActionResult|nil, err: string|nil)): boolean|{ cancel: fun() }|nil

---@param id string
---@param context AtlasIssueActionContext
---@return AtlasAction|nil
function M.find(id, context)
	return action_runner.find(utils.custom_actions(), id)
		or action_runner.find(context.provider.capabilities.actions, id)
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
	return action_runner.run(M.find(id, context), context, on_done)
end

---@param context AtlasIssueActionContext
---@param on_done fun(result: IssuesActionResult|nil, err: string|nil)|nil
---@param extra_items { label: string, icon?: string, callback: fun() }[]|nil
function M.open(context, on_done, extra_items)
	local custom = utils.custom_actions()
	local items = {}
	for _, action in ipairs(context.provider.capabilities.actions or {}) do
		if not action.hidden and not action_runner.find(custom, action.id) then
			table.insert(items, action)
		end
	end
	vim.list_extend(items, custom)
	items = vim.tbl_filter(function(action)
		return action_runner.is_available(action, context)
	end, items)
	vim.list_extend(items, extra_items or {})
	if #items == 0 then
		notify.info("No actions available")
		return
	end

	local target = context.issue and string.format(" for %s", tostring(context.issue.key)) or ""
	action_runner.select(string.format("Choose %s action%s", context.provider.name, target), items, function(item)
		if item.callback then
			item.callback()
		else
			action_runner.run(item, context, on_done)
		end
	end)
end

M.browse_repository = {
	id = "browse_repository",
	label = "Browse Current Repository",
	icon = icons.get("overview"),
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
	label = "Manage Templates",
	icon = icons.get("edit", "actions"),
	run = function(_, done)
		templates.manage(function(err)
			done(nil, err)
		end)
	end,
}

return M
