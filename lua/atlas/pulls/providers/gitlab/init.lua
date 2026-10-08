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

local activity_api = require("atlas.pulls.providers.gitlab.api.activity")
local mentions = require("atlas.providers.gitlab.mentions")
local changes_api = require("atlas.pulls.providers.gitlab.api.changes")
local checks_api = require("atlas.pulls.providers.gitlab.api.checks")
local comments_api = require("atlas.pulls.providers.gitlab.api.comments")
local config = require("atlas.config")
local detail_ui = require("atlas.pulls.providers.gitlab.ui.detail")
local git = require("atlas.core.git")
local links_api = require("atlas.providers.gitlab.links")
local pullrequests_api = require("atlas.pulls.providers.gitlab.api.pullrequests")
local reviews_api = require("atlas.pulls.providers.gitlab.api.reviews")
local repository_ui = require("atlas.providers.gitlab.ui.repository")
local gitlab_query = require("atlas.providers.gitlab.query")
local request_scope = require("atlas.core.requests")
local GITLAB_REACTION_OPTIONS = require("atlas.ui.shared.emojis").gitlab()

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
	return vim.tbl_map(function(view)
		return vim.tbl_extend("force", {}, view)
	end, configured)
end

---@param view AtlasGitLabPullsViewConfig
---@param on_done fun(view: AtlasGitLabPullsViewConfig)
---@return { cancel: fun() }|nil
local function resolve_view(view, on_done)
	if not view.current_repo then
		on_done(view)
		return nil
	end
	return git.local_repository(vim.fn.getcwd(), function(target)
		local resolved = vim.tbl_extend("force", {}, view)
		local repo = target and target.provider == "gitlab" and target.repo_full_name or nil
		if repo then
			resolved.project = repo
			resolved.scope = view.scope or "all"
		end
		on_done(resolved)
	end)
end

---@param view AtlasGitLabPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(page: PullsPage, err: string[]|nil)
---@return AtlasRequestScope
local function fetch_pullrequests(view, opts, on_done)
	local requests = request_scope.new()
	requests.run(function(done)
		return resolve_view(view, done)
	end, function(resolved)
		local query = gitlab_query.query(resolved)
		requests.run(function(done)
			return pullrequests_api.fetch_states(resolved, gitlab_query.api_states(resolved), opts, done)
		end, function(page, err)
			page.query = query
			on_done(page, err)
		end)
	end)
	return requests
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
			fetch_pullrequests = fetch_pullrequests,
			fetch_by_refs = pullrequests_api.fetch_by_refs,
			fetch_pullrequest = pullrequests_api.fetch_pullrequest,
			fetch_links = links_api.fetch_pullrequest,
			create_pr = pullrequests_api.create_pr,
			fetch_reviewers = reviews_api.fetch_reviewers,
			update_reviewers = pullrequests_api.update_reviewers,
			merge = pullrequests_api.merge,
			update_title = pullrequests_api.update_title,
			update_description = pullrequests_api.update_description,
			set_draft = pullrequests_api.set_draft,
			decline = pullrequests_api.decline,
			fetch_description = pullrequests_api.fetch_description,
			fetch_reviewer_candidates = pullrequests_api.fetch_reviewer_candidates,
			fetch_merge_checks = checks_api.fetch,
			fetch_diffstat = changes_api.fetch_diffstat,
			fetch_commits = changes_api.fetch_commits,
		},
		comments = {
			reaction_options = GITLAB_REACTION_OPTIONS,
			comment_completion = mentions.for_pulls,
			-- comment_formatter = nil,
			fetch_conversation = activity_api.fetch_conversation,
			add_comment = comments_api.add_comment,
			edit_comment = comments_api.edit_comment,
			delete_comment = comments_api.delete_comment,
			add_reaction = comments_api.add_reaction,
			set_thread_resolved = comments_api.set_thread_resolved,
		},
		reviews = {
			fetch = reviews_api.fetch,
			fetch_threads = reviews_api.fetch_threads,
			-- fetch_review_context = nil,
			-- edit_review = nil,
			-- start_review = nil,
			submit_review = reviews_api.submit,
			approve = reviews_api.approve,
			request_changes = reviews_api.request_changes,
			discard_review = reviews_api.discard,
			-- set_file_reviewed = nil,
		},
		-- tasks = {
		-- 	add_task = nil,
		-- 	edit_task = nil,
		-- 	delete_task = nil,
		-- },
		pipelines = require("atlas.pulls.pipelines.gitlab"),
		ui = {
			detail = detail_ui,
			repository = repository_ui,
		},
	},
}
