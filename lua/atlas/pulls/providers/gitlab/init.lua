local actions = require("atlas.pulls.providers.gitlab.actions")
local activity_api = require("atlas.pulls.providers.gitlab.api.activity")
local checks_api = require("atlas.pulls.providers.gitlab.api.checks")
local comments_api = require("atlas.pulls.providers.gitlab.api.comments")
local commits_api = require("atlas.pulls.providers.gitlab.api.commits")
local files_api = require("atlas.pulls.providers.gitlab.api.files")
local mergerequests_api = require("atlas.pulls.providers.gitlab.api.mergerequests")
local notifications_api = require("atlas.pulls.providers.gitlab.api.notifications")
local repositories_api = require("atlas.pulls.providers.gitlab.api.repositories")
local service = require("atlas.providers.gitlab.client").pulls
local users_api = require("atlas.pulls.providers.gitlab.api.users")
local resolver = require("atlas.providers.resolve")

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(groups: PullsGroup[], err: string[]|nil)
---@return { cancel: fun() }|nil
local function fetch_pullrequests(view, opts, on_done)
	---@cast view AtlasGitLabPullsViewConfig
	local filters = require("atlas.pulls.state").status_filters or {}
	local state = filters.MERGED and "merged" or (filters.DECLINED and "closed" or "opened")
	local parts = { string.format("is:%s", state) }
	for _, field in ipairs({
		"project",
		"group",
		"scope",
		"labels",
		"milestone",
		"author_username",
		"assignee_username",
	}) do
		if view[field] then
			table.insert(parts, string.format("%s:%s", field:gsub("_username$", ""), tostring(view[field])))
		end
	end
	if view.search and view.search ~= "" then
		table.insert(parts, tostring(view.search))
	end
	require("atlas.pulls.state").last_search_query = table.concat(parts, " ")

	return mergerequests_api.list_mrs(view, {
		force_load = opts and opts.force_load == true or false,
		pagelen = opts and opts.pagelen or 50,
		state = state,
	}, function(groups, err)
		if err then
			on_done({}, { err })
			return
		end
		on_done(groups or {}, nil)
	end)
end

---@param pr PullRequestRef
---@param opts PullsFetchOpts
---@param on_done fun(pr: PullRequest|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_pullrequest(pr, opts, on_done)
	return mergerequests_api.get_mr(pr, { force_load = opts and opts.force_load == true or false }, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: { comments: PullsComment[], events: PullsActivityEntry[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_conversation(pr, opts, on_done)
	local pending = 2
	local events_result, comments_result, first_err
	local handles = {}
	local cancelled = false

	local function finish()
		if cancelled then
			return
		end
		pending = pending - 1
		if pending > 0 then
			return
		end
		if events_result == nil and comments_result == nil then
			on_done(nil, first_err or "Failed to fetch conversation")
			return
		end
		on_done({ comments = comments_result or {}, events = events_result or {} }, nil)
	end

	local activity_handle = activity_api.fetch_activity(pr, opts, function(entries, err)
		if err then
			first_err = first_err or err
		else
			events_result = entries or {}
		end
		finish()
	end)
	if activity_handle then
		table.insert(handles, activity_handle)
	end

	local comments_handle = comments_api.fetch_general_comments(pr, opts, function(comments, err)
		if err then
			first_err = first_err or err
		else
			comments_result = comments or {}
		end
		finish()
	end)
	if comments_handle then
		table.insert(handles, comments_handle)
	end

	return {
		cancel = function()
			cancelled = true
			for _, handle in ipairs(handles) do
				handle.cancel()
			end
		end,
	}
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_diffstat(pr, opts, on_done)
	return files_api.fetch_diff(pr, opts, function(files, err)
		if not files then
			on_done(nil, err)
			return
		end

		local entries = {}
		for _, file in ipairs(files) do
			local additions, deletions = file.additions, file.deletions
			if additions == nil and deletions == nil then
				additions, deletions = 0, 0
				for _, hunk in ipairs(file.hunks) do
					additions = additions + hunk.additions
					deletions = deletions + hunk.deletions
				end
			end
			table.insert(entries, {
				status = file.status,
				path = file.path,
				old_path = file.old_path,
				lines_added = additions or 0,
				lines_removed = deletions or 0,
			})
		end
		on_done(entries, nil)
	end)
end

---@param opts { repo_slug: string, repo_root: string|nil, head: string, base: string }
---@param on_done fun(reviewers: PullsCreatePRReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_default_reviewers(opts, on_done)
	local slug = tostring(opts.repo_slug or "")
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing project slug")
		end)
		return nil
	end

	local endpoint = string.format("/projects/%s/members/all?per_page=100", service.url_encode(slug))
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local reviewers = {}
		for _, raw in ipairs(type(result) == "table" and result or {}) do
			local login = type(raw) == "table" and tostring(raw.username or "") or ""
			local id = type(raw) == "table" and tonumber(raw.id) or nil
			if login ~= "" and id then
				table.insert(reviewers, {
					label = "@" .. login,
					provider_id = tostring(id),
					selected = false,
					default = false,
				})
			end
		end
		on_done(reviewers, nil)
	end)
end

---@param opts PullsCreatePROpts
---@param on_done fun(result: PullsCreatePRResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function create_pr(opts, on_done)
	local reviewer_ids = {}
	for _, reviewer in ipairs(opts.reviewers or {}) do
		local id = tonumber(reviewer.provider_id)
		if id then
			table.insert(reviewer_ids, id)
		end
	end

	return mergerequests_api.create_mr({
		project_path = opts.repo_slug,
		source_branch = opts.head,
		target_branch = opts.base,
		title = opts.title,
		description = opts.body,
		draft = opts.draft == true,
		reviewer_ids = reviewer_ids,
	}, function(result, err)
		if err or result == nil then
			on_done(nil, err)
			return
		end
		on_done({ id = result.iid, url = result.url, message = "Merge request created" }, nil)
	end)
end

---@param opts { force_load: boolean|nil }|nil
---@param on_done fun(notifications: AtlasNotification[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_notifications(opts, on_done)
	return notifications_api.fetch(vim.tbl_extend("force", { state = "pending", per_page = 100 }, opts or {}), on_done)
end

---@return AtlasGitLabPullsViewConfig[]
local function views()
	local config = service.gitlab_config()
	local configured = config.views
		or {
			{ name = "Assigned", key = "1", scope = "assigned_to_me", state = "opened" },
			{ name = "Created", key = "2", scope = "created_by_me", state = "opened" },
		}
	return require("atlas.ui.shared.bookmarks_view").append_to_views(configured, config.bookmarks, "S", "Search")
end

local function search()
	actions.run("search", { source = "main" }, function() end)
end

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
local function resolve_target(value, parsed)
	if parsed == nil then
		return nil, nil
	end
	local path = resolver.path_for_base(parsed, resolver.configured_base("pulls", "gitlab"))
	if path == nil then
		return nil, nil
	end

	local project_path, number, tail = path:match("^/(.-)/%-/merge_requests/(%d+)(.*)$")
	local owner, repo = resolver.split_project(project_path)
	if owner then
		if not resolver.valid_tail(tail) then
			return nil, "Unsupported GitLab merge request URL"
		end
		return {
			provider = "gitlab",
			domain = "pulls",
			entity = "pr",
			url = value,
			host = parsed.host,
			owner = owner,
			repo = repo,
			project_path = project_path,
			number = tonumber(number),
		}
	end

	if not path:find("/-/", 1, true) then
		project_path = path:match("^/(.+/.+)$")
		owner, repo = resolver.split_project(project_path)
		if owner then
			return {
				provider = "gitlab",
				domain = "pulls",
				entity = "repo",
				url = value,
				host = parsed.host,
				owner = owner,
				repo = repo,
				project_path = project_path,
			}
		end
	end

	return nil, "Unsupported GitLab URL. Expected a repository, issue, or merge request URL"
end

---@param target AtlasTarget
---@return AtlasPullsViewConfig
local function search_view(target)
	return {
		name = "Search",
		layout = "compact",
		project = target.project_path,
		scope = "all",
	}
end

---@param info AtlasGitRemoteInfo
---@param domain AtlasDomain
---@param entity AtlasEntity
---@param number integer
---@param base_url string
---@return AtlasTarget
local function target(info, domain, entity, number, base_url)
	local owner, repo = info.slug:match("^(.+)/([^/]+)$")
	return {
		provider = "gitlab",
		domain = domain,
		entity = entity,
		host = info.host,
		owner = owner,
		repo = repo,
		project_path = info.slug,
		number = number,
		url = string.format(
			"%s/%s/-/%s/%d",
			base_url,
			info.slug,
			entity == "pr" and "merge_requests" or "issues",
			number
		),
	}
end

---@param options table
---@return string[]
local function repositories(options)
	local result = {}
	for _, view in ipairs(options.views or {}) do
		table.insert(result, view.project)
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
			fetch_user = users_api.fetch_user,
			fetch_pullrequests = fetch_pullrequests,
			fetch_pullrequest = fetch_pullrequest,
			fetch_description = mergerequests_api.get_description,
			fetch_reviewers = mergerequests_api.get_reviewers,
			fetch_merge_checks = checks_api.get_merge_checks,
			fetch_diffstat = fetch_diffstat,
			fetch_activity = activity_api.fetch_activity,
			fetch_commits = commits_api.fetch_commits,
			fetch_diff = files_api.fetch_diff,
			views = views,
		},
		comments = {
			reaction_options = require("atlas.ui.shared.emojis").gitlab(),
			comment_completion = require("atlas.pulls.providers.gitlab.completion.author").build_completion,
			fetch_conversation = fetch_conversation,
			add_comment = comments_api.add_comment,
			edit_comment = comments_api.edit_comment,
			delete_comment = comments_api.delete_comment,
			add_reaction = comments_api.add_reaction,
		},
		reviews = {
			fetch_review_context = mergerequests_api.get_review_context,
			fetch_comments = comments_api.fetch_comments,
			set_thread_resolved = comments_api.set_thread_resolved,
			submit_review = mergerequests_api.submit_review,
		},
		repository = {
			fetch_details = repositories_api.fetch_detail,
			fetch_branches = repositories_api.fetch_branches,
			fetch_tags = repositories_api.fetch_tags,
			delete_branch = repositories_api.delete_branch,
		},
		pipelines = {
			fetch = checks_api.get_pipelines,
			fetch_job_log = checks_api.get_pipeline_job_log,
			actions = require("atlas.pulls.providers.gitlab.actions.pipelines"),
		},
		notifications = {
			fetch = fetch_notifications,
			mark_read = notifications_api.mark_read,
			mark_done = notifications_api.mark_done,
		},
		search = search,
		create = {
			create_pr = create_pr,
			fetch_default_reviewers = fetch_default_reviewers,
		},
		actions = actions,
		ui = {
			setup = require("atlas.pulls.providers.gitlab.highlights").setup,
			render = require("atlas.pulls.providers.gitlab.ui.main").render,
			panel = require("atlas.pulls.providers.gitlab.ui.panel"),
			repo_panel = require("atlas.pulls.providers.gitlab.ui.repo_panel"),
		},
	},
}
