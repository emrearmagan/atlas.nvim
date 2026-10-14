---@class AzureIssue : Issue
---@field id integer
---@field project string
---@field description_format string|nil

---@class AzureIssueDetails : IssueDetails
--- Azure work-item formats: https://devblogs.microsoft.com/devops/markdown-support-arrives-for-work-items/
---@field description_format string|nil Format of the displayed description.

---@class AzureIssueComment : IssueComment
---@field body_format string

local config = require("atlas.config")
local issues_api = require("atlas.issues.providers.azure.api.issues")
local comments_api = require("atlas.issues.providers.azure.api.comments")
local history_api = require("atlas.issues.providers.azure.api.history")

---@return AtlasAzureIssuesViewConfig[]
local function views()
	local options = config.domain_options("azure", "issues") or {}
	return options.views or {}
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
	issue_ref = issue_ref,
	capabilities = {
		core = {
			fetch_issues = issues_api.list_issues,
			fetch_by_refs = issues_api.fetch_by_refs,
			fetch_issue = issues_api.fetch_issue,
			-- fetch_links = nil,
		},
		comments = {
			fetch_activity = history_api.fetch,
			fetch_conversation = comments_api.fetch_conversation,
			add_comment = comments_api.add_comment,
			edit_comment = comments_api.edit_comment,
			delete_comment = comments_api.delete_comment,
			reactions = {
				options = comments_api.reactions,
				add = comments_api.add_reaction,
				remove = comments_api.remove_reaction,
			},
		},
		actions = require("atlas.issues.providers.azure.actions.registry"),
		ui = {
			detail = require("atlas.issues.providers.azure.ui.detail"),
			-- repository = nil,
		},
	},
}
