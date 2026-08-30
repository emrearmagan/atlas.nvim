---@class BitbucketPullRequestLinks
---@field html string|nil
---@field self string|nil
---@field merge string|nil
---@field decline string|nil
---@field commits string|nil
---@field approve string|nil
---@field request_changes string|nil
---@field diff string|nil
---@field diffstat string|nil
---@field comments string|nil
---@field activity string|nil
---@field statuses string|nil

---@class BitbucketPullRequest : PullRequest
---@field tasks_count number
---@field links BitbucketPullRequestLinks

---@class BitbucketPullRequestDetails : PullRequestDetails
---@field close_source_branch boolean|nil

---@class BitbucketPullsRepoDetails : PullsRepoDetails
---@field branches_url string
---@field tags_url string

local actions = require("atlas.pulls.providers.bitbucket.actions")
local author_completion = require("atlas.providers.bitbucket.completion.author")
local activity_api = require("atlas.pulls.providers.bitbucket.api.activity")
local changes_api = require("atlas.pulls.providers.bitbucket.api.changes")
local comments_api = require("atlas.pulls.providers.bitbucket.api.comments")
local config = require("atlas.config")
local detail_ui = require("atlas.pulls.providers.bitbucket.ui.detail")
local git = require("atlas.core.git")
local highlights = require("atlas.pulls.providers.bitbucket.highlights")
local pipeline_actions = require("atlas.pulls.providers.bitbucket.actions.pipelines")
local pipelines_api = require("atlas.pulls.providers.bitbucket.api.pipelines")
local pullrequests_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
local repo_detail_ui = require("atlas.pulls.providers.bitbucket.ui.repo_detail")
local repositories_api = require("atlas.pulls.providers.bitbucket.api.repositories")
local reviews_api = require("atlas.pulls.providers.bitbucket.api.reviews")
local search_query = require("atlas.providers.bitbucket.query")
local tasks_api = require("atlas.pulls.providers.bitbucket.api.tasks")
local users_api = require("atlas.pulls.providers.bitbucket.api.users")

---@param target AtlasTarget
---@return AtlasBitbucketViewConfig
local function view_for_target(target)
	return {
		name = "Search",
		layout = "compact",
		search = search_query.for_repo(target.workspace, target.repo),
	}
end

---@param view AtlasBitbucketViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(page: PullsPage, err: string[]|nil)
---@return { cancel: fun() }|nil
local function fetch_pullrequests(view, opts, on_done)
	---@cast view AtlasBitbucketViewConfig
	local parsed, parse_err = search_query.parse(view.search)
	if parsed == nil then
		on_done({ items = {}, next_cursor = nil }, { parse_err })
		return nil
	end
	local states = view._states or parsed.states or { "open" }
	return pullrequests_api.fetch_for_targets(parsed.targets, {
		cursor = opts.cursor,
		force_refresh = opts.force_refresh == true,
		pagelen = opts.pagelen,
		query = search_query.filter(parsed, states),
	}, on_done)
end

---@return AtlasBitbucketViewConfig[]
local function views()
	local options = config.domain_options("bitbucket", "pulls") or {}
	local configured = options.views or {}
	if #configured == 0 then
		configured = { { name = "Pull Requests", key = "1", layout = "compact", current_repo = true } }
	end
	local current_repo
	for _, view in ipairs(configured) do
		if view.current_repo then
			local target = git.local_repository()
			if target and target.provider == "bitbucket" and target.workspace and target.repo then
				current_repo = { workspace = target.workspace, repo = target.repo }
			end
			break
		end
	end
	local result = {}
	for i, view in ipairs(configured) do
		result[i] = vim.tbl_extend("force", {}, view)
		if view.current_repo and current_repo then
			result[i].search = search_query.for_repo(current_repo.workspace, current_repo.repo, view.search)
		end
	end
	return result
end

return {
	views = views,
	view_for_target = view_for_target,
	resolve_search = search_query.query,
	capabilities = {
		core = {
			fetch_user = users_api.fetch_current_user,
			fetch_pullrequests = fetch_pullrequests,
			fetch_by_refs = pullrequests_api.fetch_by_refs,
			fetch_pullrequest = pullrequests_api.fetch_pullrequest,
			fetch_description = pullrequests_api.fetch_description,
			create_pr = pullrequests_api.create_pr,
			fetch_default_reviewers = pullrequests_api.fetch_default_reviewers,
			fetch_reviewers = pullrequests_api.fetch_reviewers,
			update_reviewers = pullrequests_api.update_reviewers,
			update_title = pullrequests_api.update_title,
			update_description = pullrequests_api.update_description,
			set_draft = pullrequests_api.set_draft,
			decline = pullrequests_api.decline,
			fetch_diffstat = changes_api.fetch_diffstat,
			fetch_commits = changes_api.fetch_commits,
			fetch_diff = changes_api.fetch_diff,
		},
		comments = {
			comment_completion = author_completion.for_pulls,
			fetch_conversation = activity_api.fetch_conversation,
			add_comment = comments_api.add_comment,
			edit_comment = comments_api.edit_comment,
			delete_comment = comments_api.delete_comment,
			set_thread_resolved = comments_api.set_thread_resolved,
		},
		reviews = {
			fetch = reviews_api.fetch_review,
			fetch_review_context = reviews_api.fetch_review_context,
			submit_review = reviews_api.submit_review,
			approve = reviews_api.approve,
			request_changes = reviews_api.request_changes,
			discard_review = reviews_api.discard_review,
		},
		tasks = {
			add_task = tasks_api.add_task,
			edit_task = tasks_api.edit_task,
			delete_task = tasks_api.delete_task,
		},
		repository = {
			fetch_details = repositories_api.fetch_detail,
			fetch_branches = repositories_api.fetch_branches,
			fetch_tags = repositories_api.fetch_tags,
			delete_branch = repositories_api.delete_branch,
		},
		pipelines = {
			fetch = pipelines_api.fetch,
			fetch_details = pipelines_api.fetch_details,
			fetch_commit_status = pipelines_api.fetch_commit_status,
			fetch_job_log = pipelines_api.fetch_job_log,
			actions = pipeline_actions,
		},
		actions = actions,
		ui = {
			setup = highlights.setup,
			detail = detail_ui,
			repo_detail = repo_detail_ui,
		},
	},
}
