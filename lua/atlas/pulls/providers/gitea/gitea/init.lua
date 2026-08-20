require("atlas.pulls.providers.gitea.config")

local checks_api = require("atlas.pulls.providers.gitea.gitea.api.checks")
local comments_api = require("atlas.pulls.providers.gitea.gitea.api.comments")
local commits_api = require("atlas.pulls.providers.gitea.gitea.api.commits")
local files_api = require("atlas.pulls.providers.gitea.gitea.api.files")
local notifications_api = require("atlas.pulls.providers.gitea.gitea.api.notifications")
local pipelines_api = require("atlas.pulls.providers.gitea.gitea.api.pipelines")
local pullrequests_api = require("atlas.pulls.providers.gitea.gitea.api.pullrequests")
local repositories_api = require("atlas.pulls.providers.gitea.gitea.api.repositories")
local reviews_api = require("atlas.pulls.providers.gitea.gitea.api.reviews")
local resolver = require("atlas.providers.resolve")
local git = require("atlas.core.git")

---@param view { repo: string|nil, search: string|nil }
---@param opts PullsFetchOpts
---@param on_done fun(groups: PullsGroup[], err: string[]|nil)
local function fetch_pullrequests(view, opts, on_done)
	local filters = require("atlas.pulls.state").status_filters or {}
	local statuses = {}
	local explicit_status = opts and opts.state and tostring(opts.state):upper() or nil
	if explicit_status then
		statuses = { explicit_status }
	else
		for _, status in ipairs({ "OPEN", "MERGED", "DECLINED" }) do
			if filters[status] then
				table.insert(statuses, status)
			end
		end
		if #statuses == 0 then
			statuses = { "OPEN" }
		end
	end

	local global = vim.trim(tostring(view.repo or "")) == ""
	local query = global and { "type:pulls" } or { "repo:" .. tostring(view.repo or "") }
	for _, status in ipairs(statuses) do
		table.insert(query, "is:" .. status:lower())
	end
	if vim.trim(tostring(view.search or "")) ~= "" then
		table.insert(query, tostring(view.search))
	end
	require("atlas.pulls.state").last_search_query = table.concat(query, " ")

	local fetch = global and pullrequests_api.search_global or pullrequests_api.list
	return fetch(view, {
		statuses = statuses,
		pagelen = opts and opts.pagelen or 50,
		force_load = opts and opts.force_load == true,
	}, function(groups, err)
		local nonempty = {}
		for _, group in ipairs(groups or {}) do
			if #group.prs > 0 then
				table.insert(nonempty, group)
			end
		end
		on_done(nonempty, err and { err } or nil)
	end)
end

---@param view AtlasGiteaForgejoPullsViewConfig
---@return AtlasGiteaForgejoPullsViewConfig
local function resolve_cur_repo(view)
	if not view.current_repo then
		return view
	end
	local root = git.repo_root()
	local info = git.local_repository(root, "pulls")
	if not info then
		return view
	end
	local resolved = vim.tbl_extend("force", {}, view)
	resolved.project = info.slug
	resolved.scope = view.scope or "all"
	return resolved
end

---@return AtlasGiteaForgejoPullsViewConfig[]
local function views()
	local cfg = require("atlas.providers").options("gitea", "pulls") or {}
	local resolved = vim.tbl_map(resolve_cur_repo, cfg.views or {})
	return require("atlas.ui.shared.bookmarks_view").append_to_views(resolved, cfg.bookmarks, "S", "Search")
end

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
local function resolve(value, parsed)
	if not parsed then
		return nil, nil
	end
	local path = resolver.path_for_base(parsed, resolver.configured_base("pulls", "gitea"))
	if path == nil then
		return nil, nil
	end

	local owner, repo, number, tail = path:match("^/([^/]+)/([^/]+)/pulls/(%d+)(.*)$")
	if owner then
		if not resolver.valid_tail(tail) then
			return nil, "Unsupported Gitea pull request URL"
		end
		return {
			provider = "gitea",
			domain = "pulls",
			entity = "pr",
			url = value,
			host = parsed.host,
			owner = owner,
			repo = repo,
			project_path = owner .. "/" .. repo,
			number = tonumber(number),
		}
	end

	owner, repo = path:match("^/([^/]+)/([^/]+)/?$")
	if owner then
		return {
			provider = "gitea",
			domain = "pulls",
			entity = "repo",
			url = value,
			host = parsed.host,
			owner = owner,
			repo = repo,
			project_path = owner .. "/" .. repo,
		}
	end

	return nil, "Unsupported Gitea URL. Expected a repository or pull request URL"
end

---@param target AtlasTarget
---@return AtlasGiteaForgejoPullsViewConfig
local function search_view(target)
	return { name = "Search", layout = "compact", repo = target.project_path }
end

---@param info AtlasGitRemoteInfo
---@param domain AtlasDomain
---@param entity AtlasEntity
---@param number integer|nil
---@param base_url string
---@return AtlasTarget
local function target(info, domain, entity, number, base_url)
	local owner, repo = info.slug:match("^([^/]+)/([^/]+)$")
	local url = string.format("%s/%s", base_url, info.slug)
	if entity == "pr" then
		url = string.format("%s/pulls/%d", url, assert(number))
	end
	return {
		provider = "gitea",
		domain = domain,
		entity = entity,
		host = info.host,
		owner = owner,
		repo = repo,
		project_path = info.slug,
		number = number,
		url = url,
	}
end

---@param options table
---@return string[]
local function repositories(options)
	local result = {}
	for _, view in ipairs(options.views or {}) do
		table.insert(result, view.repo)
	end
	return result
end

local comments = {
	fetch_conversation = comments_api.fetch,
	reaction_options = require("atlas.ui.shared.emojis").github(),
	comment_completion = require("atlas.pulls.providers.gitea.completion.author").build_completion,
	add_comment = comments_api.add,
	edit_comment = comments_api.edit,
	delete_comment = comments_api.delete,
	add_reaction = comments_api.add_reaction,
	set_thread_resolved = comments_api.set_thread_resolved,
}

local reviews = {
	fetch = reviews_api.fetch,
	fetch_review_context = reviews_api.fetch_context,
	start_review = reviews_api.start_review,
	submit_review = reviews_api.submit_review,
	approve = reviews_api.approve,
	request_changes = reviews_api.request_changes,
	discard_review = reviews_api.discard_review,
}

local repository = {
	fetch_details = repositories_api.detail,
	fetch_branches = repositories_api.branches,
	fetch_tags = repositories_api.tags,
	fetch_issues = repositories_api.fetch_issues,
	delete_branch = repositories_api.delete_branch,
}

local notifications = {
	fetch = notifications_api.fetch,
	mark_read = notifications_api.mark_read,
	mark_done = notifications_api.mark_done,
}

local actions = require("atlas.pulls.providers.gitea.gitea.actions")
local panel = require("atlas.pulls.providers.gitea.ui.panel").new(pullrequests_api)

return {
	resolve = resolve,
	search_view = search_view,
	target = target,
	repositories = repositories,
	capabilities = {
		core = {
			fetch_user = pullrequests_api.fetch_user,
			fetch_pullrequests = fetch_pullrequests,
			fetch_pullrequest = pullrequests_api.get,
			create_pr = pullrequests_api.create,
			fetch_default_reviewers = pullrequests_api.fetch_default_reviewers,
			update_reviewers = pullrequests_api.update_reviewers,
			update_title = pullrequests_api.update_title,
			update_description = pullrequests_api.update_description,
			set_draft = pullrequests_api.set_draft,
			decline = pullrequests_api.decline,
			fetch_description = pullrequests_api.description,
			fetch_reviewers = pullrequests_api.reviewers,
			fetch_merge_checks = checks_api.fetch_merge_checks,
			fetch_activity = comments_api.fetch_activity,
			fetch_diffstat = files_api.diffstat,
			fetch_commits = commits_api.fetch,
			fetch_diff = files_api.diff,
			views = views,
		},
		comments = comments,
		reviews = reviews,
		repository = repository,
		pipelines = {
			fetch = pipelines_api.fetch,
			fetch_commit_status = pipelines_api.fetch_commit_status,
			fetch_details = pipelines_api.fetch_details,
			fetch_job_log = pipelines_api.fetch_job_log,
			actions = require("atlas.pulls.providers.gitea.gitea.actions.pipelines"),
		},
		notifications = notifications,
		actions = actions,
		ui = {
			setup = require("atlas.pulls.providers.gitea.highlights").setup,
			render = require("atlas.pulls.providers.gitea.ui.main").render,
			panel = panel,
			repo_panel = require("atlas.pulls.providers.gitea.ui.repo_panel"),
		},
	},
}
