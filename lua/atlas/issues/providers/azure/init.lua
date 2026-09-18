---@class AzureIssueUser : IssueUser
---@field username string|nil

---@class AzureIssue : Issue
---@field id integer
---@field project string
---@field description_format string|nil

---@class AzureIssueComment : IssueComment
---@field body_format string

local config = require("atlas.config")
local issues_api = require("atlas.issues.providers.azure.api.issues")
local users_api = require("atlas.issues.providers.azure.api.users")
local comments_api = require("atlas.issues.providers.azure.api.comments")
local history_api = require("atlas.issues.providers.azure.api.history")
local author_completion = require("atlas.providers.azure.completion.author")
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
			update_description = issues_api.update_description,
			refresh = service.clear_cache,
		},
		comments = {
			fetch_activity = history_api.fetch,
			fetch_conversation = comments_api.fetch_conversation,
			add_comment = comments_api.add_comment,
			-- reply_comment = comments_api.reply_comment,
			edit_comment = comments_api.edit_comment,
			delete_comment = comments_api.delete_comment,
			add_reaction = comments_api.add_reaction,
			reaction_options = comments_api.reaction_options,
			comment_completion = author_completion.for_issues,
		},
		-- notifications = notifications_api,
		actions = require("atlas.issues.providers.azure.actions"),
		ui = {
			detail = require("atlas.issues.providers.azure.ui.detail"),
		},
	},
}
