local actions = require("atlas.pulls.providers.github.actions")
local activity_api = require("atlas.pulls.providers.github.api.activity")
local changes_api = require("atlas.pulls.providers.github.api.changes")
local checks_api = require("atlas.pulls.providers.github.api.checks")
local cli = require("atlas.providers.github.client").pulls
local comments_api = require("atlas.pulls.providers.github.api.comments")
local notifications_api = require("atlas.pulls.providers.github.api.notifications")
local pipelines_api = require("atlas.pulls.providers.github.api.pipelines")
local pullrequests_api = require("atlas.pulls.providers.github.api.pullrequests")
local repositories_api = require("atlas.pulls.providers.github.api.repositories")
local reviews_api = require("atlas.pulls.providers.github.api.reviews")
local users_api = require("atlas.pulls.providers.github.api.users")
local resolver = require("atlas.providers.resolve")

---@param on_done fun(user: PullsUser|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_user(on_done)
	return users_api.fetch_user(function(user, err)
		if user then
			require("atlas.pulls.providers.github.state").current_user = user
		end
		on_done(user, err)
	end)
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(groups: PullsGroup[], err: string[]|nil)
---@return { cancel: fun() }|nil
local function fetch_pullrequests(view, opts, on_done)
	---@cast view AtlasGitHubViewConfig
	local search = view.search or ""
	if search == "" then
		vim.schedule(function()
			on_done({}, { "No search query configured for view" })
		end)
		return nil
	end

	local query = search:find("is:pr") and search or "is:pr " .. search
	local filters = require("atlas.pulls.state").status_filters or {}
	local open, merged, declined = filters.OPEN, filters.MERGED, filters.DECLINED
	if opts.state == "open" or (opts.state == nil and open and not merged and not declined) then
		query = query .. " is:open"
	elseif opts.state == "merged" or (opts.state == nil and merged and not open and not declined) then
		query = query .. " is:merged"
	elseif opts.state == "declined" or (opts.state == nil and declined and not open and not merged) then
		query = query .. " is:closed -is:merged"
	elseif opts.state == nil and merged and declined and not open then
		query = query .. " is:closed"
	end

	require("atlas.pulls.state").last_search_query = query
	return pullrequests_api.search_prs(query, on_done, {
		force_load = opts.force_load == true,
		limit = opts.pagelen,
	})
end

---@param pr PullRequestRef
---@param opts PullsFetchOpts
---@param on_done fun(pr: PullRequest|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_pullrequest(pr, opts, on_done)
	local owner, repo = pr.repo_full_name:match("^([^/]+)/(.+)$")
	if owner == nil or repo == nil then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end
	return pullrequests_api.get_pr(owner, repo, pr.id, on_done, { force_load = opts.force_load == true })
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: { comments: PullsComment[], events: PullsActivityEntry[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_conversation(pr, opts, on_done)
	---@param result { comments: PullsComment[], events: PullsActivityEntry[] }
	---@param description string
	local function finish(result, description)
		local comments = type(result.comments) == "table" and result.comments or {}
		if description ~= "" then
			table.insert(comments, 1, {
				id = "__body__",
				parent_id = nil,
				author = pr.author,
				content_raw = description,
				created_on = pr.created_on or "",
				reactions = pr.reactions,
			})
		end
		on_done({ comments = comments, events = type(result.events) == "table" and result.events or {} }, nil)
	end

	return activity_api.fetch_conversation(pr, opts, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch conversation")
			return
		end

		local description = tostring(pr.description or "")
		if description ~= "" then
			finish(result, description)
			return
		end
		pullrequests_api.get_description(pr, opts, function(value)
			finish(result, tostring(value or ""))
		end)
	end)
end

---@param pr PullRequest
---@param comment PullsComment
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function add_reaction(pr, comment, key, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		on_done(false, "Missing repo")
		return nil
	end

	local endpoint
	if tostring(comment.id) == "__body__" then
		endpoint = string.format("repos/%s/issues/%s/reactions", repo_slug, tostring(pr.id))
	elseif comment.inline then
		endpoint = string.format("repos/%s/pulls/comments/%s/reactions", repo_slug, tostring(comment.id))
	else
		endpoint = string.format("repos/%s/issues/comments/%s/reactions", repo_slug, tostring(comment.id))
	end
	return cli.gh({ "api", "-X", "POST", endpoint, "-f", "content=" .. key }, function(_, err)
		on_done(err == nil, err)
	end)
end

---@return AtlasGitHubViewConfig[]
local function views()
	local config = ((require("atlas.config").options.pulls or {}).providers or {}).github or {}
	---@cast config AtlasGitHubConfig
	local configured = type(config.views) == "table" and #config.views > 0 and config.views
		or { { name = "Me", key = "1", search = "involves:@me", layout = "compact" } }
	return require("atlas.ui.shared.bookmarks_view").append_to_views(configured, config.bookmarks, "S", "Search")
end

---@param opts { force_load: boolean|nil }|nil
---@param on_done fun(notifications: AtlasNotification[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_notifications(opts, on_done)
	return notifications_api.fetch(vim.tbl_extend("force", { all = true, per_page = 100 }, opts or {}), on_done)
end

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
local function resolve_target(value, parsed)
	if parsed == nil or parsed.host ~= "github.com" then
		return nil, nil
	end

	local owner, repo, number, tail = parsed.path:match("^/([^/]+)/([^/]+)/pull/(%d+)(.*)$")
	if owner then
		if not resolver.valid_tail(tail) then
			return nil, "Unsupported GitHub pull request URL"
		end
		return {
			provider = "github",
			domain = "pulls",
			entity = "pr",
			url = value,
			host = parsed.host,
			owner = owner,
			repo = repo,
			number = tonumber(number),
		}
	end

	owner, repo = parsed.path:match("^/([^/]+)/([^/]+)$")
	if owner then
		return {
			provider = "github",
			domain = "pulls",
			entity = "repo",
			url = value,
			host = parsed.host,
			owner = owner,
			repo = repo,
		}
	end

	return nil, "Unsupported GitHub URL. Expected a repository, issue, or pull request URL"
end

---@param target AtlasTarget
---@return AtlasPullsViewConfig
local function search_view(target)
	local search = string.format("repo:%s/%s is:pr", target.owner, target.repo)
	if target.number then
		search = search .. " " .. tostring(target.number)
	end
	return {
		name = "Search",
		layout = "compact",
		search = search,
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
	local url = string.format("%s/%s/%s", base_url, owner, repo)
	if entity ~= "repo" then
		url = string.format("%s/%s/%d", url, entity == "pr" and "pull" or "issues", assert(number))
	end
	return {
		provider = "github",
		domain = domain,
		entity = entity,
		host = info.host,
		owner = owner,
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
		for slug in tostring(view.search or ""):gmatch("repo:([%w._/-]+)") do
			table.insert(result, slug)
		end
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
			fetch_user = fetch_user,
			fetch_pullrequests = fetch_pullrequests,
			fetch_pullrequest = fetch_pullrequest,
			create_pr = pullrequests_api.create_pr,
			fetch_default_reviewers = pullrequests_api.fetch_default_reviewers,
			fetch_reviewers = pullrequests_api.get_reviewers,
			update_reviewers = pullrequests_api.update_reviewers,
			update_title = pullrequests_api.update_title,
			update_description = pullrequests_api.update_description,
			set_draft = pullrequests_api.set_draft,
			decline = pullrequests_api.decline,
			fetch_description = pullrequests_api.get_description,
			fetch_merge_checks = checks_api.fetch,
			fetch_diffstat = changes_api.fetch_diffstat,
			fetch_activity = activity_api.fetch_activity,
			fetch_commits = changes_api.fetch_commits,
			fetch_diff = changes_api.fetch_diff,
			views = views,
		},
		comments = {
			reaction_options = require("atlas.ui.shared.emojis").github(),
			comment_completion = require("atlas.pulls.providers.github.completion.author").build_completion,
			fetch_conversation = fetch_conversation,
			add_comment = comments_api.add_comment,
			edit_comment = comments_api.edit_comment,
			delete_comment = comments_api.delete_comment,
			add_reaction = add_reaction,
			set_thread_resolved = comments_api.set_thread_resolved,
		},
		reviews = {
			fetch = reviews_api.fetch,
			fetch_review_context = reviews_api.fetch_context,
			start_review = reviews_api.start,
			submit_review = reviews_api.submit,
			approve = reviews_api.approve,
			request_changes = reviews_api.request_changes,
			discard_review = reviews_api.discard,
			set_file_reviewed = reviews_api.set_file_reviewed,
		},
		repository = {
			fetch_details = repositories_api.fetch_detail,
			fetch_branches = repositories_api.fetch_branches,
			fetch_tags = repositories_api.fetch_tags,
		},
		pipelines = {
			fetch = pipelines_api.fetch,
			fetch_details = pipelines_api.fetch_details,
			fetch_job_log = pipelines_api.fetch_job_log,
			actions = require("atlas.pulls.providers.github.actions.pipelines"),
		},
		notifications = {
			fetch = fetch_notifications,
			mark_read = notifications_api.mark_read,
			mark_done = notifications_api.mark_done,
		},
		actions = actions,
		ui = {
			setup = require("atlas.pulls.providers.github.highlights").setup,
			render = require("atlas.pulls.providers.github.ui.main").render,
			panel = require("atlas.pulls.providers.github.ui.panel"),
			repo_panel = require("atlas.pulls.providers.github.ui.repo_panel"),
		},
	},
}
