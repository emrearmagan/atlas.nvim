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
---@field repo BitbucketRepository
---@field tasks_count number
---@field links BitbucketPullRequestLinks

---@class BitbucketPullRequestDetails : PullRequestDetails
---@field close_source_branch boolean|nil

local mentions = require("atlas.providers.bitbucket.mentions")
local activity_api = require("atlas.pulls.providers.bitbucket.api.activity")
local changes_api = require("atlas.pulls.providers.bitbucket.api.changes")
local checks_api = require("atlas.pulls.providers.bitbucket.api.checks")
local comments_api = require("atlas.pulls.providers.bitbucket.api.comments")
local config = require("atlas.config")
local detail_ui = require("atlas.pulls.providers.bitbucket.ui.detail")
local git = require("atlas.core.git")
local pipelines = require("atlas.pulls.pipelines.bitbucket")
local pullrequests_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
local repository_ui = require("atlas.providers.bitbucket.ui.repository")
local request_scope = require("atlas.core.requests")
local reviews_api = require("atlas.pulls.providers.bitbucket.api.reviews")
local search_query = require("atlas.providers.bitbucket.query")
local tasks_api = require("atlas.pulls.providers.bitbucket.api.tasks")

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
---@param on_done fun(view: AtlasBitbucketViewConfig)
---@return { cancel: fun() }|nil
local function resolve_view(view, on_done)
	if not view.current_repo then
		on_done(view)
		return nil
	end
	return git.local_repository(vim.fn.getcwd(), function(target)
		local resolved = vim.tbl_extend("force", {}, view)
		if target and target.provider == "bitbucket" and target.workspace and target.repo then
			resolved.search = search_query.for_repo(target.workspace, target.repo, view.search)
		end
		on_done(resolved)
	end)
end

---@param view AtlasBitbucketViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(page: PullsPage, err: string[]|nil)
---@return AtlasRequestScope
local function fetch_pullrequests(view, opts, on_done)
	local requests = request_scope.new()
	requests.run(function(done)
		return resolve_view(view, done)
	end, function(resolved)
		local query = search_query.query(resolved)
		local parsed, parse_err = search_query.parse(resolved.search)
		if parsed == nil then
			on_done({ items = {}, next_cursor = nil, query = query }, { parse_err })
			return
		end
		local states = resolved._states or parsed.states or { "open" }
		requests.run(function(done)
			return pullrequests_api.fetch_for_targets(parsed.targets, {
				cursor = opts.cursor,
				force_refresh = opts.force_refresh == true,
				pagelen = opts.pagelen,
				query = search_query.filter(parsed, states),
			}, done)
		end, function(page, err)
			page.query = query
			on_done(page, err)
		end)
	end)
	return requests
end

---@return AtlasBitbucketViewConfig[]
local function views()
	local options = config.domain_options("bitbucket", "pulls") or {}
	local configured = options.views or {}
	if #configured == 0 then
		configured = { { name = "Pull Requests", key = "1", layout = "compact", current_repo = true } }
	end
	return vim.tbl_map(function(view)
		return vim.tbl_extend("force", {}, view)
	end, configured)
end

return {
	views = views,
	view_for_target = view_for_target,
	resolve_search = search_query.query,
	capabilities = {
		core = {
			fetch_pullrequests = fetch_pullrequests,
			fetch_by_refs = pullrequests_api.fetch_by_refs,
			fetch_pullrequest = pullrequests_api.fetch_pullrequest,
			-- fetch_links = nil,
			fetch_description = pullrequests_api.fetch_description,
			create_pr = pullrequests_api.create_pr,
			fetch_reviewer_candidates = pullrequests_api.fetch_reviewer_candidates,
			fetch_reviewers = pullrequests_api.fetch_reviewers,
			fetch_merge_checks = checks_api.fetch,
			update_reviewers = pullrequests_api.update_reviewers,
			merge = pullrequests_api.merge,
			update_title = pullrequests_api.update_title,
			update_description = pullrequests_api.update_description,
			set_draft = pullrequests_api.set_draft,
			decline = pullrequests_api.decline,
			fetch_diffstat = changes_api.fetch_diffstat,
			fetch_commits = changes_api.fetch_commits,
		},
		comments = {
			-- reaction_options = nil,
			comment_completion = mentions.for_pulls,
			comment_formatter = mentions.formatter,
			fetch_conversation = activity_api.fetch_conversation,
			add_comment = comments_api.add_comment,
			edit_comment = comments_api.edit_comment,
			delete_comment = comments_api.delete_comment,
			-- add_reaction = nil,
			set_thread_resolved = comments_api.set_thread_resolved,
		},
		reviews = {
			fetch = reviews_api.fetch_review,
			fetch_threads = reviews_api.fetch_threads,
			fetch_review_context = reviews_api.fetch_review_context,
			-- edit_review = nil,
			-- start_review = nil,
			submit_review = reviews_api.submit_review,
			approve = reviews_api.approve,
			request_changes = reviews_api.request_changes,
			discard_review = reviews_api.discard_review,
			-- set_file_reviewed = nil,
		},
		pipelines = pipelines,
		tasks = {
			add_task = tasks_api.add_task,
			edit_task = tasks_api.edit_task,
			delete_task = tasks_api.delete_task,
		},
		ui = {
			detail = detail_ui,
			repository = repository_ui,
		},
	},
}
