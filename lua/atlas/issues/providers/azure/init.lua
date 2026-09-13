---@class AzureIssueUser : IssueUser
---@field username string|nil

---@class AzureIssue : Issue
---@field id integer
---@field project string
---@field description_format string|nil

---@class AzureIssueDetails : IssueDetails
---@field description_format string|nil

local config = require("atlas.config")
local issues_api = require("atlas.issues.providers.azure.api.issues")
local users_api = require("atlas.issues.providers.azure.api.users")
local service = require("atlas.pulls.providers.azure.api.service")

---@return AtlasAzureIssuesViewConfig[]
local function views()
	local options = config.domain_options("azure", "issues") or {}
	return options.views or {}
end

---@param view IssuesViewConfig
---@return string
local function resolve_search(view)
	return view.search or ""
end

---@param target AtlasTarget
---@return AtlasAzureIssuesViewConfig
local function view_for_target(target)
	return {
		name = "Search",
		layout = "plain",
		project = target.project_path,
		search = "SELECT [System.Id] FROM WorkItems WHERE [System.Id] = " .. target.number,
	}
end

---@param target AtlasTarget
---@return IssueRef|nil
local function issue_ref(target)
	if target.number then
		return { key = tostring(target.number) }
	end
end

return {
	views = views,
	view_for_target = view_for_target,
	resolve_search = resolve_search,
	issue_ref = issue_ref,
	capabilities = {
		core = {
			fetch_user = users_api.fetch_user,
			fetch_issues = issues_api.list_issues,
			fetch_by_refs = issues_api.fetch_by_refs,
			fetch_issue = issues_api.fetch_issue,
			refresh = service.clear_cache,
		},
		-- notifications = notifications_api,
		ui = {
			detail = require("atlas.issues.providers.azure.ui.detail"),
		},
	},
}
