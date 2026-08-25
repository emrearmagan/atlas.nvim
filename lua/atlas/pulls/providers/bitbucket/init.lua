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
---@field close_source_branch boolean|nil
---@field links BitbucketPullRequestLinks

---@class BitbucketPullRequestDetails : PullRequestDetails, BitbucketPullRequest

local actions = require("atlas.pulls.providers.bitbucket.actions")
local activity_api = require("atlas.pulls.providers.bitbucket.api.activity")
local changes_api = require("atlas.pulls.providers.bitbucket.api.changes")
local comments_api = require("atlas.pulls.providers.bitbucket.api.comments")
local config = require("atlas.config")
local pipelines_api = require("atlas.pulls.providers.bitbucket.api.pipelines")
local pullrequests_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
local repositories_api = require("atlas.pulls.providers.bitbucket.api.repositories")
local reviews_api = require("atlas.pulls.providers.bitbucket.api.reviews")
local tasks_api = require("atlas.pulls.providers.bitbucket.api.tasks")
local users_api = require("atlas.pulls.providers.bitbucket.api.users")
local request_scope = require("atlas.core.requests")
local git = require("atlas.core.git")

---@param target AtlasTarget
---@return AtlasBitbucketViewConfig
local function search_view(target)
	return {
		name = "Search",
		layout = "compact",
		targets = { { workspace = target.workspace, repo = target.repo } },
	}
end

---@param opts PullsFetchOpts
---@return string[]
local function active_statuses(opts)
	local statuses = {}
	if opts.state then
		statuses = { opts.state:upper() }
	else
		for status, enabled in pairs(require("atlas.pulls.state").status_filters or {}) do
			if enabled then
				table.insert(statuses, status)
			end
		end
	end
	if #statuses == 0 then
		statuses = { "OPEN" }
	end
	return statuses
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@return string
local function search_query(view, opts)
	---@cast view AtlasBitbucketViewConfig
	local parts = {}
	for _, target_ref in ipairs(view.targets or view.repos or {}) do
		if target_ref.repo then
			table.insert(parts, string.format("repo:%s/%s", target_ref.workspace, target_ref.repo))
		else
			table.insert(parts, string.format("project:%s/%s", target_ref.workspace, target_ref.project))
		end
	end
	for _, status in ipairs(active_statuses(opts)) do
		table.insert(parts, string.format("is:%s", status:lower()))
	end
	return table.concat(parts, " ")
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(pulls: PullRequest[], err: string[]|nil)
---@return { cancel: fun() }|nil
local function fetch_pullrequests(view, opts, on_done)
	---@cast view AtlasBitbucketViewConfig
	local targets = view.targets or view.repos or {}
	local statuses = active_statuses(opts)

	local function finish(pulls, err)
		if type(view.filter) ~= "function" then
			on_done(pulls, err)
			return
		end

		local context = { user = require("atlas.pulls.state").current_user }
		local filtered = {}
		for _, pr in ipairs(pulls) do
			local ok, keep = pcall(view.filter, pr, context)
			if ok and keep ~= false then
				table.insert(filtered, pr)
			end
		end
		on_done(filtered, err)
	end

	local scope = request_scope.new()
	local starts = {}
	for index, target_ref in ipairs(targets) do
		if target_ref.project then
			local project = target_ref
			starts[index] = function(done)
				return repositories_api.fetch_project_repositories(project, opts, done)
			end
		end
	end

	scope.all(starts, function(project_repos, project_errors)
		local repos, errors, seen = {}, {}, {}
		for index, target_ref in ipairs(targets) do
			local resolved = target_ref.repo and { target_ref } or project_repos[index] or {}
			for _, repo in ipairs(resolved) do
				local key = repo.workspace .. "/" .. repo.repo
				if not seen[key] then
					seen[key] = true
					table.insert(repos, repo)
				end
			end
			if project_errors[index] then
				table.insert(
					errors,
					string.format("%s/%s: %s", target_ref.workspace, target_ref.project, project_errors[index])
				)
			end
		end

		scope.run(function(done)
			return pullrequests_api.fetch_pullrequests(repos, {
				force_load = opts.force_load == true,
				pagelen = opts.pagelen,
				statuses = statuses,
			}, done)
		end, function(pulls, fetch_errors)
			vim.list_extend(errors, fetch_errors or {})
			finish(pulls, #errors > 0 and errors or nil)
		end)
	end)

	return { cancel = scope.cancel }
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(branches: PullsRepoBranches|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_repo_branches(repo, opts, on_done)
	local links = type((repo._raw or {}).links) == "table" and repo._raw.links or {}
	local branches = type(links.branches) == "table" and links.branches or {}
	return repositories_api.fetch_branches(tostring(branches.href or ""), opts, on_done)
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(tags: PullsRepoTags|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_repo_tags(repo, opts, on_done)
	local links = type((repo._raw or {}).links) == "table" and repo._raw.links or {}
	local tags = type(links.tags) == "table" and links.tags or {}
	return repositories_api.fetch_tags(tostring(tags.href or ""), opts, on_done)
end

---@return AtlasBitbucketViewConfig[]
local function views()
	local options = config.domain_options("bitbucket", "pulls") or {}
	local configured = options.views or {}
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
			result[i].targets = { current_repo }
		end
	end
	if #result == 0 then
		table.insert(result, { name = "Pull Requests", key = "1", layout = "compact", targets = {} })
	end
	return result
end

return {
	views = views,
	search_view = search_view,
	capabilities = {
		core = {
			fetch_user = users_api.fetch_current_user,
			search_query = search_query,
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
			fetch_activity = activity_api.fetch_activity,
			fetch_commits = changes_api.fetch_commits,
			fetch_diff = changes_api.fetch_diff,
		},
		comments = {
			comment_completion = require("atlas.providers.bitbucket.completion.author").for_pulls,
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
			fetch_branches = fetch_repo_branches,
			fetch_tags = fetch_repo_tags,
			delete_branch = repositories_api.delete_branch,
		},
		pipelines = {
			fetch = pipelines_api.fetch_pipelines,
			fetch_commit_status = pipelines_api.fetch_commit_status,
			fetch_job_log = pipelines_api.fetch_pipeline_job_log,
			actions = require("atlas.pulls.providers.bitbucket.actions.pipelines"),
		},
		actions = actions,
		ui = {
			setup = require("atlas.pulls.providers.bitbucket.highlights").setup,
			detail = require("atlas.pulls.providers.bitbucket.ui.detail"),
			repo_detail = require("atlas.pulls.providers.bitbucket.ui.repo_detail"),
		},
	},
}
