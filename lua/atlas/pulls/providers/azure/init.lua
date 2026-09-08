---@alias AzurePullRequestMergeStatus
---| "notSet"
---| "queued"
---| "conflicts"
---| "succeeded"
---| "rejectedByPolicy"
---| "failure"

---@class AzurePullRequest : PullRequest
---@field merge_status AzurePullRequestMergeStatus|nil
---@field merge_commit_hash string|nil
---@field project_id string
---@field repository_id string

local config = require("atlas.config")
local search_query = require("atlas.providers.azure.query")
local pullrequests_api = require("atlas.pulls.providers.azure.api.pullrequests")
local users_api = require("atlas.pulls.providers.azure.api.users")
local reviews_api = require("atlas.pulls.providers.azure.api.reviews")
local checks_api = require("atlas.pulls.providers.azure.api.checks")
local changes_api = require("atlas.pulls.providers.azure.api.changes")
local activity_api = require("atlas.pulls.providers.azure.api.activity")
local comments_api = require("atlas.pulls.providers.azure.api.comments")
local repositories_api = require("atlas.pulls.providers.azure.api.repositories")
local pipelines_api = require("atlas.pulls.providers.azure.api.pipelines")
local pipeline_actions = require("atlas.pulls.providers.azure.actions.pipelines")
local author_completion = require("atlas.providers.azure.completion.author")
local actions = require("atlas.pulls.providers.azure.actions")
local detail_ui = require("atlas.pulls.providers.azure.ui.detail")
local repo_detail_ui = require("atlas.pulls.providers.azure.ui.repo_detail")

---@return AtlasAzurePullsViewConfig[]
local function views()
	local options = config.domain_options("azure", "pulls") or {}
	return options.views or {}
end

---@param target AtlasTarget
---@return AtlasAzurePullsViewConfig
local function view_for_target(target)
	return {
		name = "Search",
		layout = "compact",
		project = target.owner,
		repository = target.repo,
		scope = "all",
	}
end

return {
	views = views,
	view_for_target = view_for_target,
	resolve_search = search_query.query,
	capabilities = {
		core = {
			fetch_user = users_api.fetch_user,
			fetch_pullrequests = function(view, opts, on_done)
				return pullrequests_api.fetch_states(view, search_query.api_states(view), opts, on_done)
			end,
			fetch_by_refs = pullrequests_api.fetch_by_refs,
			fetch_pullrequest = pullrequests_api.fetch_pullrequest,
			create_pr = pullrequests_api.create_pr,
			fetch_reviewers = reviews_api.fetch_reviewers,
			update_reviewers = pullrequests_api.update_reviewers,
			update_title = pullrequests_api.update_title,
			update_description = pullrequests_api.update_description,
			set_draft = pullrequests_api.set_draft,
			decline = pullrequests_api.decline,
			fetch_description = pullrequests_api.fetch_description,
			fetch_default_reviewers = pullrequests_api.fetch_default_reviewers,
			fetch_merge_checks = checks_api.fetch,
			fetch_commits = changes_api.fetch_commits,
		},
		comments = {
			comment_completion = author_completion.for_pulls,
			fetch_conversation = activity_api.fetch_conversation,
			add_comment = comments_api.add_comment,
			edit_comment = comments_api.edit_comment,
			delete_comment = comments_api.delete_comment,
			reaction_options = { { key = "like", emoji = "👍", label = "Like" } },
			add_reaction = comments_api.add_reaction,
			set_thread_resolved = comments_api.set_thread_resolved,
		},
		reviews = {
			fetch = reviews_api.fetch,
			fetch_threads = reviews_api.fetch_threads,
			fetch_review_context = reviews_api.fetch_review_context,
			approve = reviews_api.approve,
			request_changes = reviews_api.request_changes,
		},
		repository = {
			fetch_details = repositories_api.fetch_detail,
			fetch_branches = repositories_api.fetch_branches,
			fetch_tags = repositories_api.fetch_tags,
			-- fetch_issues = repositories_api.fetch_issues,
			delete_branch = repositories_api.delete_branch,
		},
		pipelines = {
			fetch = pipelines_api.fetch,
			fetch_details = pipelines_api.fetch_details,
			fetch_commit_status = pipelines_api.fetch_commit_status,
			fetch_job_log = pipelines_api.fetch_job_log,
			actions = pipeline_actions,
		},
		-- notifications = notifications_api,
		actions = actions,
		ui = {
			detail = detail_ui,
			repo_detail = repo_detail_ui,
		},
	},
}
