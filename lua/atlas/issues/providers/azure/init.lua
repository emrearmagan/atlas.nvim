---@class AzureIssue : Issue
---@field id integer
---@field project string

---@class AzureIssueDetails : IssueDetails
--- Azure work-item formats: https://devblogs.microsoft.com/devops/markdown-support-arrives-for-work-items/
---@field description_format string|nil Format of the displayed description.

---@class AzureIssueComment : IssueComment
---@field body_format string

local config = require("atlas.config")
local git = require("atlas.core.git")
local request_scope = require("atlas.core.requests")
local issues_api = require("atlas.issues.providers.azure.api.issues")
local comments_api = require("atlas.issues.providers.azure.api.comments")
local history_api = require("atlas.issues.providers.azure.api.history")
local links_api = require("atlas.providers.azure.links")

---@return AtlasAzureIssuesViewConfig[]
local function views()
	local options = config.domain_options("azure", "issues") or {}
	local configured = options.views or {}
	if #configured == 0 then
		configured = {
			{
				name = "Assigned",
				key = "1",
				search = "SELECT [System.Id] FROM WorkItems WHERE [System.AssignedTo] = @Me"
					.. " ORDER BY [System.ChangedDate] DESC",
			},
		}
	end
	return vim.tbl_map(function(view)
		return vim.tbl_extend("force", {}, view)
	end, configured)
end

---@param view AtlasAzureIssuesViewConfig
---@param on_done fun(view: AtlasAzureIssuesViewConfig)
---@return { cancel: fun() }|nil
local function resolve_view(view, on_done)
	if not view.current_repo then
		on_done(view)
		return nil
	end
	return git.local_repository(vim.fn.getcwd(), function(target)
		local resolved = vim.tbl_extend("force", {}, view)
		if target and target.provider == "azure" and target.owner then
			resolved.project = target.owner
		end
		on_done(resolved)
	end)
end

---@param view AtlasAzureIssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(page: IssuesPage, err: string|nil)
---@return AtlasRequestScope
local function fetch_issues(view, opts, on_done)
	local requests = request_scope.new()
	requests.run(function(done)
		return resolve_view(view, done)
	end, function(resolved)
		requests.run(function(done)
			return issues_api.list_issues(resolved, opts, done)
		end, on_done)
	end)
	return requests
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
	issue_ref = issue_ref,
	capabilities = {
		core = {
			fetch_issues = fetch_issues,
			fetch_by_refs = issues_api.fetch_by_refs,
			fetch_issue = issues_api.fetch_issue,
			fetch_links = links_api.fetch_issue,
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
