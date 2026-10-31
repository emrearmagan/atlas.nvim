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
local git = require("atlas.core.git")
local request_scope = require("atlas.core.requests")
local search_query = require("atlas.providers.azure.query")
local pullrequests_api = require("atlas.pulls.providers.azure.api.pullrequests")
local reviews_api = require("atlas.pulls.providers.azure.api.reviews")
local checks_api = require("atlas.pulls.providers.azure.api.checks")
local changes_api = require("atlas.pulls.providers.azure.api.changes")
local activity_api = require("atlas.pulls.providers.azure.api.activity")
local comments_api = require("atlas.pulls.providers.azure.api.comments")

---@return AtlasAzurePullsViewConfig[]
local function views()
	local options = config.domain_options("azure", "pulls") or {}
	return vim.tbl_map(function(view)
		return vim.tbl_extend("force", {}, view)
	end, options.views or {})
end

---@param view AtlasAzurePullsViewConfig
---@param on_done fun(view: AtlasAzurePullsViewConfig)
---@return { cancel: fun() }|nil
local function resolve_view(view, on_done)
	if not view.current_repo then
		on_done(view)
		return nil
	end
	return git.local_repository(vim.fn.getcwd(), function(target)
		local resolved = vim.tbl_extend("force", {}, view)
		if target and target.provider == "azure" and target.owner and target.repo then
			resolved.project = target.owner
			resolved.repository = target.repo
			resolved.scope = view.scope or "all"
		end
		on_done(resolved)
	end)
end

---@param view AtlasAzurePullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(page: PullsPage, err: string[]|nil)
---@return AtlasRequestScope
local function fetch_pullrequests(view, opts, on_done)
	local requests = request_scope.new()
	requests.run(function(done)
		return resolve_view(view, done)
	end, function(resolved)
		local query = search_query.query(resolved)
		requests.run(function(done)
			return pullrequests_api.fetch_states(resolved, search_query.api_states(resolved), opts, done)
		end, function(page, err)
			page.query = query
			on_done(page, err)
		end)
	end)
	return requests
end

---@param repository AtlasTarget
---@param branch string|nil
---@return AtlasAzurePullsViewConfig
local function repository_view(repository, branch)
	return {
		name = "Search",
		layout = "compact",
		project = repository.owner,
		repository = repository.repo,
		scope = "all",
		extra_params = branch and { ["searchCriteria.sourceRefName"] = "refs/heads/" .. branch } or nil,
	}
end

return {
	views = views,
	repository_view = repository_view,
	resolve_search = search_query.query,
	capabilities = {
		actions = require("atlas.pulls.providers.azure.actions.registry"),
		core = {
			fetch_pullrequests = fetch_pullrequests,
			fetch_by_refs = pullrequests_api.fetch_by_refs,
			fetch_pullrequest = pullrequests_api.fetch_pullrequest,
			-- fetch_links = nil,
			fetch_reviewers = reviews_api.fetch_reviewers,
			merge = pullrequests_api.merge,
			decline = pullrequests_api.decline,
			fetch_description = pullrequests_api.fetch_description,
			fetch_merge_checks = checks_api.fetch,
			-- fetch_diffstat = nil,
			fetch_commits = changes_api.fetch_commits,
		},
		write = {
			create = pullrequests_api.create_pr,
			update = pullrequests_api.update_pr,
			fetch_reviewer_candidates = pullrequests_api.fetch_reviewer_candidates,
			-- fetch_labels = nil,
			-- fetch_assignees = nil,
		},
		comments = {
			fetch_conversation = activity_api.fetch_conversation,
			add_comment = comments_api.add_comment,
			edit_comment = comments_api.edit_comment,
			delete_comment = comments_api.delete_comment,
			reactions = {
				options = { { name = "thumbsup", key = "like" } },
				add = comments_api.add_reaction,
			},
			set_thread_resolved = comments_api.set_thread_resolved,
		},
		reviews = {
			fetch = reviews_api.fetch,
			fetch_threads = reviews_api.fetch_threads,
			-- fetch_review_context = nil,
			-- edit_review = nil,
			-- start_review = nil,
			-- submit_review = nil,
			approve = reviews_api.approve,
			request_changes = reviews_api.request_changes,
			-- discard_review = nil,
			-- set_file_reviewed = nil,
		},
		-- tasks = {
		-- 	add_task = nil,
		-- 	edit_task = nil,
		-- 	delete_task = nil,
		-- },
		pipelines = require("atlas.pulls.pipelines.azure"),
		ui = {
			detail = require("atlas.pulls.providers.azure.ui.detail"),
			repository = require("atlas.providers.azure.ui.repository"),
		},
	},
}
