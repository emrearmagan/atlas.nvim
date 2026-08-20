local actions = require("atlas.pulls.providers.bitbucket.actions")
local activity_api = require("atlas.pulls.providers.bitbucket.api.activity")
local changes_api = require("atlas.pulls.providers.bitbucket.api.changes")
local comments_api = require("atlas.pulls.providers.bitbucket.api.comments")
local pipelines_api = require("atlas.pulls.providers.bitbucket.api.pipelines")
local pullrequests_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
local repositories_api = require("atlas.pulls.providers.bitbucket.api.repositories")
local reviews_api = require("atlas.pulls.providers.bitbucket.api.reviews")
local tasks_api = require("atlas.pulls.providers.bitbucket.api.tasks")
local users_api = require("atlas.pulls.providers.bitbucket.api.users")
local resolver = require("atlas.providers.resolve")
local git = require("atlas.core.git")

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
local function resolve_target(value, parsed)
	if parsed == nil then
		return nil, nil
	end
	if parsed.host == "bitbucket.org" then
		local workspace, repo, number, tail = parsed.path:match("^/([^/]+)/([^/]+)/pull%-requests/(%d+)(.*)$")
		if workspace then
			if not resolver.valid_tail(tail) then
				return nil, "Unsupported Bitbucket pull request URL"
			end
			return {
				provider = "bitbucket",
				domain = "pulls",
				entity = "pr",
				url = value,
				host = parsed.host,
				workspace = workspace,
				owner = workspace,
				repo = repo,
				number = tonumber(number),
			}
		end

		workspace, repo = parsed.path:match("^/([^/]+)/([^/]+)$")
		if workspace then
			return {
				provider = "bitbucket",
				domain = "pulls",
				entity = "repo",
				url = value,
				host = parsed.host,
				workspace = workspace,
				owner = workspace,
				repo = repo,
			}
		end

		return nil, "Unsupported Bitbucket URL. Expected a Cloud repository or pull request URL"
	end

	local project, repo, number, tail = parsed.path:match("^/projects/([^/]+)/repos/([^/]+)/pull%-requests/(%d+)(.*)$")
	local server_pr = project and repo and number and resolver.valid_tail(tail)
	local server_repo = parsed.path:match("^/projects/[^/]+/repos/[^/]+$")
	if server_pr or server_repo then
		return nil,
			"Bitbucket Server/Data Center URLs are recognized, but this Atlas provider currently supports Bitbucket Cloud only"
	end

	return nil, nil
end

---@param target AtlasTarget
---@return AtlasPullsViewConfig
local function search_view(target)
	return {
		name = "Search",
		layout = "compact",
		repos = { { workspace = target.workspace, repo = target.repo } },
	}
end

---@param info AtlasGitRemoteInfo
---@param domain AtlasDomain
---@param entity AtlasEntity
---@param number integer|nil
---@param base_url string
---@return AtlasTarget
local function target(info, domain, entity, number, base_url)
	local owner, repo = info.slug:match("^(.+)/([^/]+)$")
	local url = string.format("%s/%s", base_url, info.slug)
	if entity ~= "repo" then
		url = string.format("%s/pull-requests/%d", url, assert(number))
	end
	return {
		provider = "bitbucket",
		domain = domain,
		entity = entity,
		host = info.host,
		owner = owner,
		workspace = owner,
		repo = repo,
		number = number,
		url = url,
	}
end

---@param options table
---@return string[]
local function repositories(options)
	local result = {}
	for _, view in ipairs(options.views or {}) do
		for _, repo in ipairs(view.repos or {}) do
			table.insert(result, tostring(repo.workspace or "") .. "/" .. tostring(repo.repo or ""))
		end
	end
	return result
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(pulls: PullRequest[], err: string[]|nil)
---@return { cancel: fun() }|nil
local function fetch_pullrequests(view, opts, on_done)
	---@cast view AtlasBitbucketViewConfig
	local active_statuses = {}
	if opts.state then
		active_statuses = { opts.state:upper() }
	else
		for status, enabled in pairs(require("atlas.pulls.state").status_filters or {}) do
			if enabled then
				table.insert(active_statuses, status)
			end
		end
	end
	if #active_statuses == 0 then
		active_statuses = { "OPEN" }
	end

	local workspaces, repos, seen_workspaces = {}, {}, {}
	for _, ref in ipairs(view.repos or {}) do
		local workspace = tostring(ref.workspace or "")
		if workspace ~= "" and not seen_workspaces[workspace] then
			seen_workspaces[workspace] = true
			table.insert(workspaces, workspace)
		end
		local repo = tostring(ref.repo or "")
		if repo ~= "" then
			table.insert(repos, repo)
		end
	end

	local parts = {}
	if #workspaces > 0 then
		table.insert(parts, string.format("workspace:%s", table.concat(workspaces, ",")))
	end
	if #repos > 0 then
		table.insert(parts, string.format("repo:%s", table.concat(repos, ",")))
	end
	for _, status in ipairs(active_statuses) do
		table.insert(parts, string.format("is:%s", status:lower()))
	end
	require("atlas.pulls.state").last_search_query = table.concat(parts, " ")

	return pullrequests_api.fetch_pullrequests(view.repos or {}, {
		force_load = opts.force_load == true,
		pagelen = opts.pagelen,
		statuses = active_statuses,
	}, function(pulls, err)
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
	end)
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


---@param view AtlasBitbucketViewConfig
---@return AtlasBitbucketRepoRef[]|nil
local function resolve_cur_repo(view)
    if not view.current_repo then
        return view
    end
    local root = git.repo_root()
    local info = git.local_repository(root)
    if not info then
        return view
    end
    return { { workspace = info.owner, repo = info.repo } }
end



---@return AtlasBitbucketViewConfig[]
local function views()
	local config = (((require("atlas.config").options or {}).pulls or {}).providers or {}).bitbucket
	local result = {}
	for _, view in ipairs((config and config.views) or {}) do
		table.insert(result, {
			name = view.name,
			key = view.key,
			layout = view.layout,
			repos = resolve_cur_repo(view),
			filter = view.filter,
		})
	end
	if #result == 0 then
		table.insert(result, { name = "Pull Requests", key = "1", layout = "compact", repos = {} })
	end
	return result
end

return {
	resolve = resolve_target,
	search_view = search_view,
	target = target,
	repositories = repositories,
	capabilities = {
		core = {
			fetch_user = users_api.fetch_current_user,
			fetch_pullrequests = fetch_pullrequests,
			fetch_pullrequest = pullrequests_api.fetch_pullrequest,
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
			views = views,
		},
		comments = {
			comment_completion = require("atlas.pulls.providers.bitbucket.completion.author").build_completion,
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
			panel = require("atlas.pulls.providers.bitbucket.ui.panel"),
			repo_panel = require("atlas.pulls.providers.bitbucket.ui.repo_panel"),
		},
	},
}
