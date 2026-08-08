local actions = require("atlas.pulls.providers.bitbucket.actions")
local comments_api = require("atlas.pulls.providers.bitbucket.api.comments")
local pipelines_api = require("atlas.pulls.providers.bitbucket.api.pipelines")
local pullrequests_api = require("atlas.pulls.providers.bitbucket.api.pullrequests")
local repositories_api = require("atlas.pulls.providers.bitbucket.api.repositories")
local users_api = require("atlas.pulls.providers.bitbucket.api.users")
local diff_parser = require("atlas.core.git.diff_parser")
local resolver = require("atlas.providers.resolve")

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
---@param number integer
---@param base_url string
---@return AtlasTarget
local function target(info, domain, entity, number, base_url)
	local owner, repo = info.slug:match("^(.+)/([^/]+)$")
	return {
		provider = "bitbucket",
		domain = domain,
		entity = entity,
		host = info.host,
		owner = owner,
		workspace = owner,
		repo = repo,
		number = number,
		url = string.format("%s/%s/pull-requests/%d", base_url, info.slug, number),
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
---@param on_done fun(groups: PullsGroup[], err: string[]|nil)
---@return { cancel: fun() }|nil
local function fetch_pullrequests(view, opts, on_done)
	---@cast view AtlasBitbucketViewConfig
	local active_statuses = {}
	for status, enabled in pairs(require("atlas.pulls.state").status_filters or {}) do
		if enabled then
			table.insert(active_statuses, status)
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
	}, function(groups, err)
		if type(view.filter) ~= "function" then
			on_done(groups, err)
			return
		end

		local context = { user = require("atlas.pulls.state").current_user }
		local filtered = {}
		for _, group in ipairs(groups or {}) do
			local prs = {}
			for _, pr in ipairs(group.prs or {}) do
				local ok, keep = pcall(view.filter, pr, context)
				if ok and keep ~= false then
					table.insert(prs, pr)
				end
			end
			if #prs > 0 then
				table.insert(filtered, vim.tbl_extend("force", group, { prs = prs }))
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

---@return AtlasBitbucketViewConfig[]
local function views()
	local config = (((require("atlas.config").options or {}).pulls or {}).providers or {}).bitbucket
	local result = {}
	for _, view in ipairs((config and config.views) or {}) do
		table.insert(result, {
			name = view.name,
			key = view.key,
			layout = view.layout,
			repos = view.repos,
			filter = view.filter,
		})
	end
	if #result == 0 then
		table.insert(result, { name = "Pull Requests", key = "1", layout = "compact", repos = {} })
	end
	return result
end

---@param commit PullsCommit
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(status: string|nil, url: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_commit_status(commit, opts, on_done)
	local statuses_url = tostring(commit.statuses_url or "")
	if statuses_url == "" then
		on_done("unknown", nil, nil)
		return nil
	end
	return pipelines_api.fetch_commit_status(statuses_url, opts, on_done)
end

---@param comment PullsComment
---@param files DiffFile[]|nil
local function attach_hunk(comment, files)
	if not comment.inline or not files then
		return
	end
	local side = comment.inline.to ~= nil and "new" or "old"
	local line = comment.inline.to or comment.inline.from
	if not line then
		return
	end
	for _, file in ipairs(files) do
		if file.path == comment.inline.path or file.old_path == comment.inline.path then
			local hunk = diff_parser.find_hunk(file, side, line)
			if hunk then
				comment.inline_hunk = hunk
				return
			end
		end
	end
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_comments(pr, opts, on_done)
	opts = opts or {}
	local comments_result, diff_result, comments_err
	local handles = {}
	local cancelled = false

	local function finish()
		if cancelled or comments_result == nil or diff_result == nil then
			return
		end
		local comments = {}
		for _, comment in ipairs(comments_result) do
			if comment.inline then
				attach_hunk(comment, diff_result)
				table.insert(comments, comment)
			end
		end
		on_done(comments, comments_err)
	end

	local comments_handle = comments_api.fetch_comments(pr, opts, function(comments, err)
		comments_err = err
		comments_result = err and {} or (comments or {})
		finish()
	end)
	if comments_handle then
		table.insert(handles, comments_handle)
	end

	local diff_handle = pullrequests_api.fetch_diff(
		pr,
		{ force_refresh = opts.force_refresh == true },
		function(files, err)
			diff_result = err and {} or (files or {})
			finish()
		end
	)
	if diff_handle then
		table.insert(handles, diff_handle)
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
---@param on_done fun(result: { comments: PullsComment[], events: PullsActivityEntry[] }|nil, err: string|nil)
---@return { cancel: fun() }
local function fetch_conversation(pr, opts, on_done)
	local cancelled = false
	local comments_handle, activity_handle
	comments_handle = comments_api.fetch_comments(pr, opts, function(result, err)
		if cancelled then
			return
		end
		if err then
			on_done(nil, err)
			return
		end

		local comments = {}
		for _, comment in ipairs(result or {}) do
			if comment.inline == nil then
				table.insert(comments, comment)
			end
		end
		activity_handle = pullrequests_api.fetch_activity(pr, opts, function(events)
			if not cancelled then
				local timeline = {}
				for _, event in ipairs(events or {}) do
					if event.kind ~= "comment" then
						table.insert(timeline, event)
					end
				end
				on_done({ comments = comments, events = timeline }, nil)
			end
		end)
	end)

	return {
		cancel = function()
			cancelled = true
			if comments_handle then
				comments_handle.cancel()
			end
			if activity_handle then
				activity_handle.cancel()
			end
		end,
	}
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(tasks: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_tasks(pr, opts, on_done)
	opts = opts or {}
	return comments_api.fetch_tasks(
		tostring(pr.workspace or ""),
		tostring(pr.repo or ""),
		pr.id,
		{ force_refresh = opts.force_refresh == true },
		function(tasks, err)
			if err then
				on_done(nil, err)
				return
			end
			tasks = tasks or {}
			table.sort(tasks, function(a, b)
				return tostring(a.created_on or "") < tostring(b.created_on or "")
			end)
			on_done(tasks, nil)
		end
	)
end

---@param pr PullRequest
---@param content string
---@param parent PullsComment|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function add_task(pr, content, parent, on_done)
	return comments_api.create_task(
		tostring(pr.workspace or ""),
		tostring(pr.repo or ""),
		pr.id,
		content,
		{ comment_id = parent and parent.id or nil, pending = parent ~= nil and parent.state == "PENDING" },
		function(created, err)
			if err or not created then
				on_done(nil, err or "Bitbucket did not return the created task")
				return
			end
			on_done(created, nil)
		end
	)
end

---@param task PullsComment
---@param on_done fun(task: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function edit_task(task, on_done)
	local task_url = tostring(task.url or "")
	if task_url == "" then
		vim.schedule(function()
			on_done(nil, "Missing task URL")
		end)
		return nil
	end
	return comments_api.update_task(task_url, {
		content_raw = task.content_raw,
		state = task.state == "RESOLVED" and "RESOLVED" or "UNRESOLVED",
	}, function(updated, err)
		if err or not updated then
			on_done(nil, err or "Bitbucket did not return the updated task")
			return
		end
		on_done(updated, nil)
	end)
end

---@param task PullsComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function delete_task(task, on_done)
	local task_url = tostring(task.url or "")
	if task_url == "" then
		vim.schedule(function()
			on_done(false, "Missing task URL")
		end)
		return nil
	end
	return comments_api.delete_task(task_url, function(_, err)
		on_done(err == nil, err)
	end)
end

---@param pr PullRequest
---@param root PullsComment
---@param resolved boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function set_thread_resolved(pr, root, resolved, on_done)
	return comments_api.set_thread_resolved(pr, root.parent_id or root.id, resolved, on_done)
end

local function search()
	actions.run("search", { source = "main" }, function() end)
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
			fetch_reviewers = pullrequests_api.fetch_reviewers,
			fetch_diffstat = pullrequests_api.fetch_diffstat,
			fetch_activity = pullrequests_api.fetch_activity,
			fetch_commits = pullrequests_api.fetch_commits,
			fetch_diff = pullrequests_api.fetch_diff,
			views = views,
		},
		comments = {
			comment_completion = require("atlas.pulls.providers.bitbucket.completion.author").build_completion,
			fetch_conversation = fetch_conversation,
			add_comment = comments_api.add_comment,
			edit_comment = comments_api.edit_comment,
			delete_comment = comments_api.delete_comment,
		},
		reviews = {
			fetch_review_context = pullrequests_api.fetch_review_context,
			fetch_comments = fetch_comments,
			fetch_tasks = fetch_tasks,
			add_task = add_task,
			edit_task = edit_task,
			delete_task = delete_task,
			set_thread_resolved = set_thread_resolved,
			submit_review = pullrequests_api.submit_review,
		},
		repository = {
			fetch_details = repositories_api.fetch_detail,
			fetch_branches = fetch_repo_branches,
			fetch_tags = fetch_repo_tags,
			delete_branch = repositories_api.delete_branch,
		},
		pipelines = {
			fetch = pipelines_api.fetch_pipelines,
			fetch_commit_status = fetch_commit_status,
			fetch_job_log = pipelines_api.fetch_pipeline_job_log,
			actions = require("atlas.pulls.providers.bitbucket.actions.pipelines"),
		},
		search = search,
		create = {
			create_pr = pullrequests_api.create_pr,
			fetch_default_reviewers = pullrequests_api.fetch_default_reviewers,
		},
		actions = actions,
		ui = {
			setup = require("atlas.pulls.providers.bitbucket.highlights").setup,
			panel = require("atlas.pulls.providers.bitbucket.ui.panel"),
		},
	},
}
