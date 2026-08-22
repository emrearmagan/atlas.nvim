require("atlas.pulls.providers.forgejo.config")

local checks_api = require("atlas.pulls.providers.forgejo.api.checks")
local comments_api = require("atlas.pulls.providers.forgejo.api.comments")
local commits_api = require("atlas.pulls.providers.forgejo.api.commits")
local files_api = require("atlas.pulls.providers.forgejo.api.files")
local notifications_api = require("atlas.pulls.providers.forgejo.api.notifications")
local pipelines_api = require("atlas.pulls.providers.forgejo.api.pipelines")
local pullrequests_api = require("atlas.pulls.providers.forgejo.api.pullrequests")
local repositories_api = require("atlas.pulls.providers.forgejo.api.repositories")
local reviews_api = require("atlas.pulls.providers.forgejo.api.reviews")
local resolver = require("atlas.providers.resolve")

---@param view { repo: string|nil, search: string|nil }
---@param opts PullsFetchOpts
---@param on_done fun(pulls: PullRequest[], err: string[]|nil)
local function fetch_pullrequests(view, opts, on_done)
	local filters = require("atlas.pulls.state").status_filters or {}
	local statuses = {}
	local explicit_status = opts.state and opts.state:upper() or nil
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

	local global = vim.trim(view.repo or "") == ""
	local query = global and { "type:pulls" } or { "repo:" .. view.repo }
	for _, status in ipairs(statuses) do
		table.insert(query, "is:" .. status:lower())
	end
	if vim.trim(view.search or "") ~= "" then
		table.insert(query, view.search)
	end
	require("atlas.pulls.state").last_search_query = table.concat(query, " ")

	local fetch = global and pullrequests_api.search_global or pullrequests_api.list
	return fetch(view, {
		statuses = statuses,
		pagelen = opts.pagelen or 50,
		force_load = opts.force_load == true,
	}, function(pulls, err)
		if err then
			on_done({}, { err })
			return
		end
		on_done(pulls, nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: PullsConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_conversation(pr, opts, on_done)
	return comments_api.fetch(pr, opts, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local ordered = {}
		local sequence = 0
		local function add(kind, created_on, entity, id)
			sequence = sequence + 1
			table.insert(ordered, {
				sequence = sequence,
				item = {
					id = id,
					kind = kind,
					created_on = created_on,
					entity = entity,
				},
			})
		end

		for _, comment in ipairs(result.comments) do
			if tostring(comment.id) ~= "__body__" then
				add("comment", comment.created_on, comment, "comment:" .. tostring(comment.id))
			end
		end
		for index, event in ipairs(result.events) do
			local created_on = event.date
			local id = table.concat({ "activity", created_on, event.kind, tostring(index) }, ":")
			add("activity", created_on, event, id)
		end

		table.sort(ordered, function(left, right)
			if left.item.created_on == right.item.created_on then
				return left.sequence < right.sequence
			end
			return left.item.created_on < right.item.created_on
		end)

		local items = {}
		for _, value in ipairs(ordered) do
			table.insert(items, value.item)
		end
		on_done(items, nil)
	end)
end

---@param pr PullRequest
---@param item PullsConversationItem
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function add_reaction(pr, item, key, on_done)
	local target = item.entity
	if item.kind == "description" then
		target = { id = "__body__" }
	elseif item.kind ~= "comment" then
		on_done(false, "This item does not support reactions")
		return nil
	end
	return comments_api.add_reaction(pr, target, key, on_done)
end

---@return AtlasForgejoPullsViewConfig[]
local function views()
	local cfg = require("atlas.config").domain_options("forgejo", "pulls")
	return cfg.views or {}
end

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
local function resolve(value, parsed)
	if not parsed then
		return nil, nil
	end
	local path = resolver.path_for_base(parsed, resolver.configured_base("pulls", "forgejo"))
	if path == nil then
		return nil, nil
	end

	local owner, repo, number, tail = path:match("^/([^/]+)/([^/]+)/pulls/(%d+)(.*)$")
	if owner then
		if not resolver.valid_tail(tail) then
			return nil, "Unsupported Forgejo pull request URL"
		end
		return {
			provider = "forgejo",
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
			provider = "forgejo",
			domain = "pulls",
			entity = "repo",
			url = value,
			host = parsed.host,
			owner = owner,
			repo = repo,
			project_path = owner .. "/" .. repo,
		}
	end

	return nil, "Unsupported Forgejo URL. Expected a repository or pull request URL"
end

---@param target AtlasTarget
---@return AtlasForgejoPullsViewConfig
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
		provider = "forgejo",
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

---@param options AtlasForgejoPullsConfig
---@return string[]
local function repositories(options)
	local result, seen = {}, {}
	---@param value string|nil
	local function add(value)
		local repo = vim.trim(value or "")
		if repo ~= "" and not seen[repo] then
			seen[repo] = true
			table.insert(result, repo)
		end
	end

	for _, view in ipairs(options.views or {}) do
		add(view.repo)
	end

	local bookmark_repos = {}
	for _, bookmark in pairs((options.bookmarks or {}).items or {}) do
		local repo = vim.trim(bookmark.repo or "")
		if repo ~= "" then
			table.insert(bookmark_repos, repo)
		end
	end
	table.sort(bookmark_repos)
	for _, repo in ipairs(bookmark_repos) do
		add(repo)
	end
	return result
end

local comments = {
	fetch_conversation = fetch_conversation,
	reaction_options = require("atlas.ui.shared.emojis").github(),
	comment_completion = require("atlas.pulls.providers.forgejo.completion.author").build_completion,
	add_comment = comments_api.add,
	edit_comment = comments_api.edit,
	delete_comment = comments_api.delete,
	add_reaction = add_reaction,
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

local actions = require("atlas.pulls.providers.forgejo.actions")
local panel = require("atlas.pulls.providers.forgejo.ui.panel")

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
			actions = require("atlas.pulls.providers.forgejo.actions.pipelines"),
		},
		notifications = notifications,
		actions = actions,
		ui = {
			setup = require("atlas.providers.forgejo.highlights").setup,
			render = require("atlas.pulls.providers.forgejo.ui.main").render,
			panel = panel,
			repo_panel = require("atlas.pulls.providers.forgejo.ui.repo_panel"),
		},
	},
}
