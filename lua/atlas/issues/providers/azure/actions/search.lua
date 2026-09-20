local M = {}

local picker = require("atlas.ui.picker")
local notify = require("atlas.core.notify")
local issues_api = require("atlas.issues.providers.azure.api.issues")
local projects_api = require("atlas.issues.providers.azure.api.projects")

---@param title string
---@param on_select fun(project: string)
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function select_project(title, on_select, done)
	notify.loading("Loading projects...")
	projects_api.fetch_projects(function(projects, err)
		if err then
			notify.error(err)
			done(nil, err)
			return
		end
		notify.clear()
		---@cast projects table[]
		picker.select({
			title = title,
			items = projects,
			format_item = function(project)
				return project.name
			end,
			on_select = function(project)
				if project then
					on_select(project.name)
				else
					done(nil, nil)
				end
			end,
		})
	end)
end

---@param project string
---@param context AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function search_issues(project, context, done)
	picker.search({
		title = "Search " .. project .. " Work Items",
		fetch_on_open = false,
		format_item = function(item)
			return item.label
		end,
		preview_item = function(item, preview_done)
			local issue = item.value
			return issues_api.fetch_issue(issue, nil, function(details, err)
				if err then
					preview_done({ title = issue.key, lines = { err } })
					return
				end
				---@cast details IssueDetails
				local assignees = vim.tbl_map(function(user)
					return "@" .. user.display_name
				end, details.assignees)
				local labels = vim.tbl_map(function(label)
					return label.name
				end, details.labels)
				local lines = {
					"**Status:** " .. issue.status,
					"**Author:** " .. (issue.reporter and issue.reporter.display_name or "Unknown"),
					"**Assignees:** " .. (#assignees > 0 and table.concat(assignees, ", ") or "Unassigned"),
				}
				if #labels > 0 then
					table.insert(lines, "**Labels:** " .. table.concat(labels, ", "))
				end
				vim.list_extend(lines, { "", "## Description", "" })
				local description = vim.trim(details.description)
				vim.list_extend(
					lines,
					vim.split(description ~= "" and description or "No description", "\n", { plain = true })
				)
				preview_done({ title = item.label, lines = lines })
			end)
		end,
		fetch = function(query, fetch_done)
			query = vim.trim(query)
			if query == "" then
				fetch_done({}, nil)
				return
			end
			---@type AtlasAzureIssuesViewConfig
			local view = {
				name = "Search",
				project = project,
				search = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project"
					.. " AND [System.Title] CONTAINS '"
					.. query:gsub("'", "''")
					.. "' ORDER BY [System.ChangedDate] DESC",
			}
			return issues_api.list_issues(view, { pagelen = 30 }, function(page, err)
				if err then
					fetch_done(nil, err)
					return
				end
				local items = {}
				for _, issue in ipairs(page.items) do
					table.insert(items, {
						id = issue.key,
						label = string.format("%s - %s", issue.key, issue.title),
						value = issue,
					})
				end
				fetch_done(items, nil)
			end)
		end,
		on_select = function(item)
			require("atlas.issues.ui.detail").open(item.value, { provider = context.provider })
			done(nil, nil)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param context AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
function M.issues(context, done)
	select_project("Search Work Items - Project", function(project)
		search_issues(project, context, done)
	end, done)
end

---@param _ AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
function M.project(_, done)
	select_project("Open Project", function(project)
		require("atlas").open("issues", "azure", {
			initial_view = {
				name = "Search",
				layout = "plain",
				project = project,
				search = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project"
					.. " ORDER BY [System.ChangedDate] DESC",
			},
		})
		done(nil, nil)
	end, done)
end

return M
