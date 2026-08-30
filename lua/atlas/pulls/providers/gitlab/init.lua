---@class GitLabPullRequestDiffRefs
---@field base_sha string|nil
---@field head_sha string|nil
---@field start_sha string|nil

---@class GitLabPullRequest : PullRequest
---@field merge_status string|nil
---@field detailed_merge_status string|nil
---@field diff_refs GitLabPullRequestDiffRefs|nil

---@class GitLabPullsLabel : PullsLabel
---@field text_color string|nil

---@class GitLabPullRequestDetails : PullRequestDetails
---@field assignees PullsAuthor[]
---@field labels GitLabPullsLabel[]

---@class GitLabPullsActivityEntry : PullsActivityEntry
---@field inline_thread boolean|nil

local actions = require("atlas.pulls.providers.gitlab.actions")
local activity_api = require("atlas.pulls.providers.gitlab.api.activity")
local author_completion = require("atlas.providers.gitlab.completion.author")
local changes_api = require("atlas.pulls.providers.gitlab.api.changes")
local checks_api = require("atlas.pulls.providers.gitlab.api.checks")
local comments_api = require("atlas.pulls.providers.gitlab.api.comments")
local config = require("atlas.config")
local detail_ui = require("atlas.pulls.providers.gitlab.ui.detail")
local highlights = require("atlas.pulls.providers.gitlab.highlights")
local notifications_api = require("atlas.providers.gitlab.notifications")
local pipeline_actions = require("atlas.pulls.providers.gitlab.actions.pipelines")
local pipelines_api = require("atlas.pulls.providers.gitlab.api.pipelines")
local pullrequests_api = require("atlas.pulls.providers.gitlab.api.pullrequests")
local repositories_api = require("atlas.pulls.providers.gitlab.api.repositories")
local reviews_api = require("atlas.pulls.providers.gitlab.api.reviews")
local repo_detail_ui = require("atlas.pulls.providers.gitlab.ui.repo_detail")
local gitlab_query = require("atlas.providers.gitlab.query")
local users_api = require("atlas.pulls.providers.gitlab.api.users")
local git = require("atlas.core.git")
local request_scope = require("atlas.core.requests")
local GITLAB_REACTION_OPTIONS = require("atlas.ui.shared.emojis").gitlab()

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: PullsConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_conversation(pr, opts, on_done)
	local requests = request_scope.new()
	requests.all({
		activity = function(done)
			return activity_api.fetch_activity(pr, opts, done)
		end,
		comments = function(done)
			return comments_api.fetch_conversation_comments(pr, opts, done)
		end,
	}, function(values, errors)
		if values.activity == nil and values.comments == nil then
			on_done(nil, errors.activity or errors.comments or "Failed to fetch conversation")
			return
		end
		local items = {}
		for _, comment in ipairs(values.comments or {}) do
			table.insert(items, {
				id = "comment:" .. tostring(comment.id),
				kind = "comment",
				created_on = comment.created_on or "",
				entity = comment,
			})
		end
		for _, event in ipairs(values.activity or {}) do
			table.insert(items, {
				id = table.concat({ "activity", event.date or "", event.kind or "" }, ":"),
				kind = "activity",
				created_on = event.date or "",
				entity = event,
			})
		end
		on_done(items, errors.activity or errors.comments)
	end)
	return requests
end

---@return AtlasGitLabPullsViewConfig[]
local function views()
	local options = config.domain_options("gitlab", "pulls") or {}
	local configured = options.views
	if not configured or #configured == 0 then
		configured = {
			{ name = "Assigned", key = "1", scope = "assigned_to_me" },
			{ name = "Created", key = "2", scope = "created_by_me" },
		}
	end
	local repo
	for _, view in ipairs(configured) do
		if view.current_repo then
			local target = git.local_repository()
			if target and target.provider == "gitlab" then
				repo = target.repo_full_name
			end
			break
		end
	end
	local resolved = {}
	for i, view in ipairs(configured) do
		resolved[i] = vim.tbl_extend("force", {}, view)
		if view.current_repo and repo then
			resolved[i].project = repo
			resolved[i].scope = view.scope or "all"
		end
	end
	return resolved
end

---@param target AtlasTarget
---@return AtlasPullsViewConfig
local function view_for_target(target)
	return {
		name = "Search",
		layout = "compact",
		project = target.project_path,
		scope = "all",
	}
end

return {
	views = views,
	view_for_target = view_for_target,
	resolve_search = gitlab_query.query,
	capabilities = {
		core = {
			fetch_user = users_api.fetch_user,
			fetch_pullrequests = function(view, opts, on_done)
				---@cast view AtlasGitLabPullsViewConfig
				return pullrequests_api.fetch_states(view, gitlab_query.api_states(view), opts, on_done)
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
			fetch_diffstat = changes_api.fetch_diffstat,
			fetch_commits = changes_api.fetch_commits,
			fetch_diff = changes_api.fetch_diff,
		},
		comments = {
			reaction_options = GITLAB_REACTION_OPTIONS,
			comment_completion = author_completion.for_pulls,
			fetch_conversation = fetch_conversation,
			add_comment = comments_api.add_comment,
			edit_comment = comments_api.edit_comment,
			delete_comment = comments_api.delete_comment,
			add_reaction = comments_api.add_reaction,
			set_thread_resolved = comments_api.set_thread_resolved,
		},
		reviews = {
			fetch = reviews_api.fetch,
			submit_review = reviews_api.submit,
			approve = reviews_api.approve,
			request_changes = reviews_api.request_changes,
			discard_review = reviews_api.discard,
		},
		repository = {
			fetch_details = repositories_api.fetch_detail,
			fetch_branches = repositories_api.fetch_branches,
			fetch_tags = repositories_api.fetch_tags,
			fetch_issues = repositories_api.fetch_issues,
			delete_branch = repositories_api.delete_branch,
		},
		pipelines = {
			fetch = pipelines_api.fetch,
			fetch_details = pipelines_api.fetch_details,
			fetch_job_log = pipelines_api.fetch_job_log,
			actions = pipeline_actions,
		},
		notifications = notifications_api,
		actions = actions,
		ui = {
			setup = highlights.setup,
			detail = detail_ui,
			repo_detail = repo_detail_ui,
		},
	},
}
