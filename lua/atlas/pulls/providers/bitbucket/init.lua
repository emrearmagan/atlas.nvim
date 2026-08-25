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
local tasks_api = require("atlas.pulls.providers.bitbucket.api.tasks")
local users_api = require("atlas.pulls.providers.bitbucket.api.users")
local request_scope = require("atlas.core.requests")

---@param target AtlasTarget
---@return AtlasBitbucketViewConfig
local function search_view(target)
	return {
		name = "Search",
		layout = "compact",
		targets = { { workspace = target.workspace, repo = target.repo } },
	}
end

---@param view AtlasBitbucketViewConfig
---@param opts PullsFetchOpts
---@return string[]
local function active_statuses(view, opts)
	if view.status ~= nil then
		return { view.status }
	end
	local statuses = {}
	for _, status in ipairs(opts.states or {}) do
		table.insert(statuses, status:upper())
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
	for _, status in ipairs(active_statuses(view, opts)) do
		table.insert(parts, string.format("is:%s", status:lower()))
	end
	return table.concat(parts, " ")
end

---@param view AtlasBitbucketViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(pulls: PullRequest[], err: string[]|nil)
---@return { cancel: fun() }|nil
local function fetch_unfiltered(view, opts, on_done)
	local targets = view.targets or view.repos or {}
	local statuses = active_statuses(view, opts)

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
			on_done(pulls, #errors > 0 and errors or nil)
		end)
	end)

	return { cancel = scope.cancel }
end

---@param pulls PullRequest[]
---@param filter fun(pr: PullRequest, ctx: { user: PullsUser|nil }): boolean|nil
---@param current_user PullsUser|nil
---@return PullRequest[]
local function apply_filter(pulls, filter, current_user)
	local filtered = {}
	for _, pr in ipairs(pulls) do
		local ok, keep = pcall(filter, pr, { user = current_user })
		if ok and keep ~= false then
			table.insert(filtered, pr)
		end
	end
	return filtered
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(pulls: PullRequest[], err: string[]|nil)
---@return { cancel: fun() }|nil
local function fetch_pullrequests(view, opts, on_done)
	---@cast view AtlasBitbucketViewConfig
	local filter = view.filter
	if filter == nil then
		return fetch_unfiltered(view, opts, on_done)
	end

	if opts.current_user ~= nil then
		return fetch_unfiltered(view, opts, function(pulls, errors)
			on_done(apply_filter(pulls, filter, opts.current_user), errors)
		end)
	end

	local scope = request_scope.new()
	scope.all({
		pulls = function(done)
			return fetch_unfiltered(view, opts, function(pulls, errors)
				done({ items = pulls, errors = errors }, nil)
			end)
		end,
		user = function(done)
			return users_api.fetch_current_user(done)
		end,
	}, function(values, request_errors)
		local result = values.pulls
		local errors = vim.list_extend({}, result.errors or {})
		if request_errors.user then
			table.insert(errors, "Current user: " .. request_errors.user)
		end
		on_done(apply_filter(result.items, filter, values.user), #errors > 0 and errors or nil)
	end)
	return scope
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
