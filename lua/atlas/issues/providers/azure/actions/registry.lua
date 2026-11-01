local actions = require("atlas.issues.actions")
local icons = require("atlas.ui.shared.icons")
local issues_api = require("atlas.issues.providers.azure.api.issues")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local search = require("atlas.issues.providers.azure.actions.search")
local users = require("atlas.providers.azure.users")

---@type AtlasIssueAction[]
local ACTIONS = {}

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
	search.select_project("Project", on_select, done)
end

register({
	id = "transition",
	label = "Change state",
	icon = icons.get("transition", "actions"),
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
			---@cast states table[]
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
	id = "edit_issue",
	label = "Edit Issue",
	icon = icons.get("edit", "actions"),
	is_available = has_issue,
	run = function(context, done)
		local issue = assert(context.issue)
		---@cast issue AzureIssue
		return require("atlas.issues.providers.azure.ui.editor").edit(issue, function(updated, err)
			if updated then
				notify.success("Work item updated", { timeout = 1200 })
			end
			done(updated and { issue_key = updated.key } or nil, err)
		end)
	end,
})

register({
	id = "assign",
	label = "Assign work item",
	icon = icons.get("user", "actions"),
	is_available = has_issue,
	run = function(context, done)
		local issue = assert(context.issue)
		---@cast issue AzureIssue
		notify.loading("Loading members...")
		users.fetch_project_members(issue.project, function(members, err)
			if err then
				notify.error(err)
				done(nil, err)
				return
			end
			notify.clear()
			local items = { { name = "Unassigned", username = "" } }
			local seen = {}
			for _, member in ipairs(members or {}) do
				local user = users.to_user(member)
				if user and user.username and not seen[user.username] then
					seen[user.username] = true
					table.insert(items, user)
				end
			end
			picker.select({
				title = "Assign work item #" .. issue.key,
				items = items,
				format_item = function(user)
					if user.username == "" then
						return user.name
					end
					return string.format("%s %s (%s)", icons.get("user"), user.name, user.username)
				end,
				on_select = function(user)
					if user then
						update(issue, { ["System.AssignedTo"] = user.username }, done)
					else
						done(nil, nil)
					end
				end,
			})
		end)
	end,
})

register({
	id = "labels",
	label = "Edit tags",
	icon = icons.get("label", "actions"),
	is_available = has_issue,
	run = function(context, done)
		local issue = assert(context.issue)
		issues_api.fetch_issue(issue, {}, function(details, err)
			if err then
				notify.error(err)
				done(nil, err)
				return
			end
			---@cast details AzureIssueDetails
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
	icon = icons.get("create", "actions"),
	run = function(context, done)
		with_project(context, function(project)
			require("atlas.issues.providers.azure.ui.editor").open(project, function(issue, err)
				if issue then
					notify.success("Work item created", { timeout = 1200 })
				end
				done(issue and { issue_key = issue.key } or nil, err)
			end)
		end, done)
	end,
})

register({
	id = "delete_issue",
	label = "Delete work item",
	icon = icons.get("delete", "actions"),
	confirm = function(context)
		return string.format("Move work item #%s to the recycle bin?", assert(context.issue).key)
	end,
	is_available = has_issue,
	run = function(context, done)
		local issue = assert(context.issue)
		issues_api.delete(issue, function(ok, err)
			if not ok then
				notify.error(err)
				done(nil, err)
				return
			end
			notify.success("Work item moved to recycle bin", { timeout = 1200 })
			done({ issue_key = issue.key, removed = true }, nil)
		end)
	end,
})

register({
	id = "search",
	label = "Search work items",
	icon = icons.get("search", "actions"),
	run = search.issues,
})

register({
	id = "open_project",
	label = "Open Project",
	icon = icons.get("search", "actions"),
	run = search.project,
})

register({
	id = "search_wiql",
	label = "Search WIQL",
	icon = icons.get("search", "actions"),
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
	icon = icons.get("search", "actions"),
	run = function(_, done)
		local state = require("atlas.issues.state")
		local query = vim.trim(state.query:gsub("[\r\n\t]+[ \t]*", " "))
		vim.ui.input({ prompt = "WIQL: ", default = query }, function(input)
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

return ACTIONS
