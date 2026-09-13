local M = {}

local actions = require("atlas.issues.actions")
local icons = require("atlas.ui.shared.icons")
local issues_api = require("atlas.issues.providers.azure.api.issues")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")

---@type AtlasIssueAction[]
local ACTIONS = {}
M.items = ACTIONS

---@param action AtlasIssueAction
local function register(action)
	table.insert(ACTIONS, action)
end

---@param context AtlasIssueActionContext
---@return boolean, string|nil
local function has_issue(context)
	return context.issue ~= nil, "No work item selected"
end

---@param issue Issue
---@param fields table<string, any>
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function update(issue, fields, done)
	notify.loading("Updating work item...")
	issues_api.update(issue, fields, function(ok, err)
		if not ok then
			notify.error(err)
			done(nil, err)
			return
		end
		notify.success("Work item updated", { timeout = 1200 })
		done({ issue_key = issue.key }, nil)
	end)
end

---@param context AtlasIssueActionContext
---@param on_select fun(project: string)
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function with_project(context, on_select, done)
	local state = require("atlas.issues.state")
	local view = state.provider == context.provider and state.search_view() or nil
	---@cast view AtlasAzureIssuesViewConfig|nil
	local issue = context.issue
	---@cast issue AzureIssue|nil
	local project = context.project_path or (issue and issue.project) or (view and view.project)
	if project then
		on_select(project)
		return
	end
	vim.ui.input({ prompt = "Azure project: " }, function(input)
		if input == nil or vim.trim(input) == "" then
			done(nil, nil)
			return
		end
		on_select(vim.trim(input))
	end)
end

register({
	id = "transition",
	label = "Change state",
	icon = icons.action("transition"),
	is_available = has_issue,
	run = function(context, done)
		local issue = assert(context.issue)
		notify.loading("Loading work item states...")
		issues_api.list_states(issue, function(states, err)
			if err then
				notify.error(err)
				done(nil, err)
				return
			end
			notify.clear()
			picker.select({
				title = "Work item state",
				items = states,
				format_item = function(state)
					return state.name
				end,
				on_select = function(state)
					if state then
						update(issue, { ["System.State"] = state.name }, done)
					else
						done(nil, nil)
					end
				end,
			})
		end)
	end,
})

register({
	id = "edit_title",
	label = "Edit title",
	icon = icons.action("edit"),
	is_available = has_issue,
	run = function(context, done)
		local issue = assert(context.issue)
		vim.ui.input({ prompt = "Title: ", default = issue.title }, function(title)
			if title == nil or vim.trim(title) == "" then
				done(nil, nil)
				return
			end
			update(issue, { ["System.Title"] = vim.trim(title) }, done)
		end)
	end,
})

register({
	id = "assign",
	label = "Assign work item",
	icon = icons.action("user"),
	is_available = has_issue,
	run = function(context, done)
		local issue = assert(context.issue)
		local assignee = issue.assignee
		---@cast assignee AzureIssueUser|nil
		vim.ui.input(
			{ prompt = "Assignee email (empty to unassign): ", default = assignee and assignee.username or "" },
			function(input)
				if input == nil then
					done(nil, nil)
					return
				end
				update(issue, { ["System.AssignedTo"] = vim.trim(input) }, done)
			end
		)
	end,
})

register({
	id = "labels",
	label = "Edit tags",
	icon = icons.action("label"),
	is_available = has_issue,
	run = function(context, done)
		local issue = assert(context.issue)
		issues_api.fetch_issue(issue, {}, function(details, err)
			if err then
				notify.error(err)
				done(nil, err)
				return
			end
			local names = vim.tbl_map(function(label)
				return label.name
			end, details.labels)
			vim.ui.input({ prompt = "Tags (separated by ;): ", default = table.concat(names, "; ") }, function(input)
				if input == nil then
					done(nil, nil)
					return
				end
				update(issue, { ["System.Tags"] = input }, done)
			end)
		end)
	end,
})

register({
	id = "create_issue",
	label = "Create work item",
	icon = icons.action("create"),
	run = function(context, done)
		with_project(context, function(project)
			notify.loading("Loading work item types...")
			issues_api.list_types(project, function(types, err)
				if err then
					notify.error(err)
					done(nil, err)
					return
				end
				notify.clear()
				require("atlas.issues.create.azure.issue").open(project, types, function(issue, create_err)
					if issue then
						notify.success("Work item created", { timeout = 1200 })
						done({ issue_key = issue.key }, nil)
					else
						done(nil, create_err)
					end
				end)
			end)
		end, done)
	end,
})

register({
	id = "delete_issue",
	label = "Delete work item",
	icon = icons.action("delete"),
	is_available = has_issue,
	run = function(context, done)
		local issue = assert(context.issue)
		vim.ui.input({ prompt = "Move work item #" .. issue.key .. " to the recycle bin? [y/N]: " }, function(input)
			if vim.trim(input or ""):lower() ~= "y" then
				done(nil, nil)
				return
			end
			issues_api.delete(issue, function(ok, err)
				if not ok then
					notify.error(err)
					done(nil, err)
					return
				end
				notify.success("Work item moved to recycle bin", { timeout = 1200 })
				done({ issue_key = issue.key, removed = true }, nil)
			end)
		end)
	end,
})

register({
	id = "search",
	label = "Search work items (WIQL)",
	icon = icons.action("search"),
	run = function(context, done)
		with_project(context, function(project)
			vim.ui.input({
				prompt = "WIQL: ",
				default = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project",
			}, function(input)
				if input and vim.trim(input) ~= "" then
					require("atlas").open("issues", "azure", {
						initial_view = { name = "Search", layout = "plain", project = project, search = input },
					})
				end
				done(nil, nil)
			end)
		end, done)
	end,
})

register({
	id = "edit_search",
	label = "Edit WIQL",
	icon = icons.action("search"),
	run = function(_, done)
		local state = require("atlas.issues.state")
		vim.ui.input({ prompt = "WIQL: ", default = state.query }, function(input)
			local view = state.search_view()
			if view and input and vim.trim(input) ~= "" then
				view.search = input
				require("atlas.issues.ui.dashboard.controller").refresh_view()
			end
			done(nil, nil)
		end)
	end,
})

register(actions.manage_templates)
register(actions.browse_issue)
register(actions.copy_issue_key)
register(actions.copy_issue_url)

---@param id string
---@return AtlasIssueAction|nil
function M.find(id)
	for _, action in ipairs(ACTIONS) do
		if action.id == id then
			return action
		end
	end
end

return M
