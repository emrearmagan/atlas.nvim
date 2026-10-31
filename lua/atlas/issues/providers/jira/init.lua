---@class JiraIssueProject
---@field id string
---@field key string
---@field name string
---@field self string
---@field category table|nil

---@class JiraIssue : Issue
---@field id string
---@field project JiraIssueProject|nil
---@field priority string|nil

---@class JiraIssueStatus : IssueStatus
---@field category string|nil

---@class JiraIssueCustomField
---@field name string
---@field formatted string
---@field hl_group string|nil
---@field display "chip"|"table"

---@class JiraFieldValue
---@field label string
---@field value any

---@class JiraMetaField
---@field name string
---@field required boolean
---@field kind "select"|"multi_select"|"sprint"|"text"|"paragraph"|"number"|"date"|"labels"|nil
---@field options { id: string, name: string }[]
---@field initial JiraFieldValue|nil

---@class JiraIssueDetails : IssueDetails
---@field type IssueType|nil
---@field status string|nil
---@field priority string|nil
---@field reporter AtlasUser|nil
---@field raw_description table|string|nil
---@field custom_fields JiraIssueCustomField[]

local comments_api = require("atlas.issues.providers.jira.api.comments")
local config = require("atlas.config")
local detail_ui = require("atlas.issues.providers.jira.ui.detail")
local issues_api = require("atlas.issues.providers.jira.api.issues")
local projects_api = require("atlas.issues.providers.jira.api.projects")
local links_api = require("atlas.issues.providers.jira.api.links")
local requests = require("atlas.core.requests")
local notify = require("atlas.core.notify")

local CATEGORY_ORDER = { new = 1, indeterminate = 2, done = 3 }

---@param view IssuesViewConfig
---@return string
local function resolve_search(view)
	---@cast view AtlasJiraViewConfig
	return tostring(view.jql or view.search or "")
end

---@param target AtlasTarget
---@return IssueRef|nil
local function target_issue_ref(target)
	if target.issue_key then
		return { key = target.issue_key }
	end
end

---@param view IssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(page: IssuesPage, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_issues(view, opts, on_done)
	local jql = resolve_search(view)
	if jql == "" then
		on_done({ items = {}, query = jql }, "Missing Jira view JQL")
		return nil
	end

	local scope = requests.new()
	scope.run(function(done)
		return issues_api.search_issues(jql, done, {
			force_refresh = opts.force_refresh == true,
			pagelen = opts.pagelen,
			cursor = opts.cursor,
		})
	end, function(page, err)
		if err or page == nil then
			on_done({ items = {}, query = jql }, err or "Failed to fetch issues")
			return
		end
		page.query = jql
		if view.layout ~= "board" then
			on_done(page, nil)
			return
		end
		local projects = {}
		for _, issue in ipairs(page.items) do
			local project = issue.project and (issue.project.id or issue.project.key)
			if project and project ~= "" then
				projects[project] = function(done)
					return projects_api.get_statuses(project, done)
				end
			end
		end
		scope.all(projects, function(results, errors)
			---@type JiraIssueStatus[]
			local statuses = {}
			for _, result in pairs(results) do
				vim.list_extend(statuses, result)
			end
			table.sort(statuses, function(a, b)
				local a_rank, b_rank = CATEGORY_ORDER[a.category] or 4, CATEGORY_ORDER[b.category] or 4
				if a_rank ~= b_rank then
					return a_rank < b_rank
				end
				if a.name:lower() ~= b.name:lower() then
					return a.name:lower() < b.name:lower()
				end
				return a.id < b.id
			end)
			if next(errors) then
				notify.warn("Failed to load board statuses: " .. table.concat(vim.tbl_values(errors), "; "))
			end
			on_done(vim.tbl_extend("force", page, { statuses = statuses }), nil)
		end)
	end)
	return { cancel = scope.cancel }
end

---@return AtlasJiraViewConfig[]
local function views()
	local configured = (config.domain_options("jira", "issues") or {}).views
	if not configured or #configured == 0 then
		configured = {
			{
				name = "Issues",
				key = "1",
				jql = "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC",
			},
		}
	end
	return configured
end

return {
	views = views,
	issue_ref = target_issue_ref,
	capabilities = {
		actions = require("atlas.issues.providers.jira.actions.registry"),
		core = {
			fetch_issues = fetch_issues,
			fetch_by_refs = issues_api.fetch_by_refs,
			fetch_issue = issues_api.fetch_issue,
			fetch_links = links_api.fetch,
		},
		comments = {
			fetch_activity = issues_api.fetch_activity,
			fetch_conversation = comments_api.fetch_conversation,
			add_comment = comments_api.add_comment,
			edit_comment = comments_api.edit_comment,
			delete_comment = comments_api.delete_comment,
			-- reactions = nil,
		},
		ui = {
			detail = detail_ui,
			-- repository = nil,
		},
	},
}
