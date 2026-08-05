local M = {}

local service = require("atlas.pulls.providers.bitbucket.api.service")
local mapper = require("atlas.pulls.providers.bitbucket.api.server.mapper")
local cache = require("atlas.core.cache")
local logger = require("atlas.core.logger")
local http = require("atlas.core.http")
local state = require("atlas.pulls.providers.bitbucket.state")

---@param link any
---@return string
local function link_href(link)
	if type(link) == "string" then
		return link
	end
	if type(link) == "table" then
		return tostring(link.href or "")
	end
	return ""
end

---@param pr PullRequest
---@param key string
---@return string
local function pr_link(pr, key)
	local raw = pr._raw
	local links = type(raw.links) == "table" and raw.links or {}
	local link = links[key]
	if link == nil and key == "request_changes" then
		link = links["request-changes"]
	end
	return link_href(link)
end

---@param pr PullRequest
---@param action "merge"|"approve"|"request_changes"
---@return boolean
function M.has_action(pr, action)
	return pr_link(pr, action) ~= ""
end

---@param workspace string  project key on Server
---@param repo string
---@param statuses string[]
---@return string
local function cache_key(workspace, repo, statuses)
	local sorted = vim.deepcopy(statuses)
	table.sort(sorted)
	return string.format("bitbucket-server:prs:%s/%s:%s", workspace, repo, table.concat(sorted, ","))
end

---@param status string
---@return string  Server `state` query value
local function server_state(status)
	local s = tostring(status or ""):upper()
	if s == "MERGED" then
		return "MERGED"
	elseif s == "DECLINED" or s == "SUPERSEDED" then
		return "DECLINED"
	end
	return "OPEN"
end

---@param workspace string
---@param repo string
---@param opts { force: boolean, limit: number|nil, statuses: string[]|nil, cache_ttl: number }
---@param on_done fun(prs: PullRequest[], err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
local function fetch_pullrequests_single(workspace, repo, opts, on_done)
	local statuses_for_key = opts.statuses or { state.pr_state }
	local key = cache_key(workspace, repo, statuses_for_key)
	if not opts.force then
		local cached = cache.get(key)
		if cached and cached.value then
			logger.loginfo("Bitbucket Server cache hit", { workspace = workspace, repo = repo })
			on_done(cached.value, nil)
			return nil
		end
	end

	-- TODO: Server's `state` param takes ONE value (OPEN/MERGED/DECLINED/ALL).
	-- For multiple statuses we'd need parallel requests; for now use the first
	-- (or ALL if more than one is requested).
	local statuses = opts.statuses or { state.pr_state }
	local state_param = #statuses > 1 and "ALL" or server_state(statuses[1])
	local endpoint = string.format(
		"/projects/%s/repos/%s/pull-requests?state=%s&limit=%d",
		workspace,
		repo,
		state_param,
		tonumber(opts.limit) or 50
	)

	logger.loginfo("Fetching Bitbucket Server pull requests", {
		workspace = workspace,
		repo = repo,
		state = state_param,
	})

	local user, token, _ = service.get_auth()
	local headers = service.build_headers(user, token)

	return http.curl_request("GET", service.url(endpoint), headers, nil, function(result, err)
		if err then
			logger.logerror("Bitbucket Server PR fetch failed", { workspace = workspace, repo = repo, error = err })
			on_done({}, err)
			return
		end

		if type(result) ~= "table" then
			on_done({}, "Bitbucket Server response is not a JSON object")
			return
		end

		local api_err = service.api_error_message(result)
		if api_err then
			logger.logerror("Bitbucket Server PR fetch API error", {
				workspace = workspace,
				repo = repo,
				error = api_err,
			})
			on_done({}, api_err)
			return
		end

		local normalized = mapper.to_pull_requests_list(result, workspace, repo)
		cache.set(key, normalized, opts.cache_ttl)
		logger.loginfo("Bitbucket Server fetch success", {
			workspace = workspace,
			repo = repo,
			pr_count = #normalized,
		})
		on_done(normalized, nil)
	end)
end

---@param view_repos AtlasBitbucketRepoRef[]
---@param opts { force_load: boolean, pagelen: number|nil, statuses: string[]|nil }
---@param on_done fun(groups: PullsGroup[], err: string[]|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequests(view_repos, opts, on_done)
	if view_repos == nil or #view_repos == 0 then
		on_done({}, nil)
		return nil
	end

	logger.loginfo("Bitbucket Server batch fetch start", { repo_count = #view_repos })

	local ttl = service.cache_ttl()
	local _, _, auth_err = service.get_auth()
	if auth_err then
		logger.logerror("Bitbucket auth missing", { error = auth_err })
		on_done({}, { tostring(auth_err) })
		return nil
	end

	local pending = #view_repos
	local done = false
	local all_prs = {}
	local errors = {}
	local handles = {}

	local function cancel_all()
		done = true
		for _, handle in ipairs(handles) do
			if handle and handle.cancel then
				pcall(handle.cancel)
			end
		end
	end

	local function finish(prs, err)
		if done then
			return
		end
		if err then
			table.insert(errors, tostring(err))
		end
		for _, pr in ipairs(prs or {}) do
			table.insert(all_prs, pr)
		end
		pending = pending - 1
		if pending == 0 then
			done = true
			logger.loginfo("Bitbucket Server batch fetch completed", {
				repo_count = #view_repos,
				pr_count = #all_prs,
				error_count = #errors,
			})
			local groups = mapper.to_pull_request_groups(all_prs)
			on_done(groups, #errors > 0 and errors or nil)
		end
	end

	for _, repo in ipairs(view_repos) do
		local handle = fetch_pullrequests_single(repo.workspace, repo.repo, {
			cache_ttl = ttl,
			force = opts.force_load,
			limit = opts.pagelen,
			statuses = opts.statuses,
		}, finish)
		if handle ~= nil then
			table.insert(handles, handle)
		end
	end

	return { cancel = cancel_all }
end

---@param pr PullRequestRef
---@param opts? { force_load?: boolean }
---@param on_done fun(detail: PullRequest|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_pullrequest(pr, opts, on_done)
	opts = opts or {}
	local workspace, repo = tostring(pr.repo_full_name or ""):match("^([^/]+)/(.+)$")
	if workspace == nil or repo == nil then
		on_done(nil, "PR missing project/repo info")
		return nil
	end
	local pr_id = pr.id
	if pr_id == nil or tostring(pr_id) == "" then
		on_done(nil, "PR missing id")
		return nil
	end

	local key = string.format("bitbucket-server:pr:detail:%s/%s/%s", workspace, repo, tostring(pr_id))
	if opts.force_load ~= true then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/projects/%s/repos/%s/pull-requests/%s", workspace, repo, tostring(pr_id))
	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local prs = mapper.to_pull_requests_list({ values = { result } }, workspace, repo)
		if #prs == 0 then
			on_done(nil, "Invalid pull request response")
			return
		end
		service.set_cache(key, prs[1], service.cache_ttl())
		on_done(prs[1], nil)
	end, {
		action = "Bitbucket Server PR detail",
		workspace = workspace,
		repo = repo,
		pr_id = pr_id,
	})
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(context: { authors: PullsAuthor[] }|nil, err: string|nil)
---@return nil
function M.fetch_review_context(pr, _opts, on_done)
	local authors = {}
	local seen = {}

	---@param author PullsAuthor|nil
	local function add(author)
		if author == nil then
			return
		end
		local key = tostring(author.id or "")
		if key == "" then
			key = tostring(author.username or author.nickname or author.name or "")
		end
		if key == "" or seen[key] then
			return
		end
		seen[key] = true
		table.insert(authors, author)
	end

	add(pr.author)
	for _, reviewer in ipairs(pr._raw.reviewers or {}) do
		local user = type(reviewer) == "table" and reviewer.user or nil
		if type(user) == "table" then
			local id = tostring(user.id or "")
			local username = tostring(user.name or user.slug or "")
			local name = tostring(user.displayName or user.name or username)
			if id ~= "" or username ~= "" or name ~= "" then
				add({
					id = id,
					name = name,
					username = username,
					nickname = username ~= "" and username or nil,
				})
			end
		end
	end

	on_done({ authors = authors }, nil)
end

---@param status any  Server reviewer status: "APPROVED"|"UNAPPROVED"|"NEEDS_WORK"
---@return "approved"|"changes_requested"|"pending"
local function reviewer_decision(status)
	local s = tostring(status or ""):upper()
	if s == "APPROVED" then
		return "approved"
	elseif s == "NEEDS_WORK" then
		return "changes_requested"
	end
	return "pending"
end

---@param pr PullRequest
---@param _opts any
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_reviewers(pr, _opts, on_done) ---@diagnostic disable-line: unused-local
	if pr == nil or pr.workspace == nil or pr.repo == nil or pr.id == nil then
		on_done(nil, "Missing PR identity")
		return nil
	end

	local endpoint = string.format("/projects/%s/repos/%s/pull-requests/%s", pr.workspace, pr.repo, tostring(pr.id))
	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		---@type PullsReviewer[]
		local reviewers = {}
		for _, item in ipairs((type(result) == "table" and result.reviewers) or {}) do
			local p = type(item) == "table" and item or {}
			local user = type(p.user) == "table" and p.user or {}
			table.insert(reviewers, {
				name = tostring(user.displayName or user.name or ""),
				nickname = tostring(user.name or ""),
				decision = reviewer_decision(p.status),
			})
		end

		on_done(reviewers, nil)
	end, {
		action = "Bitbucket Server PR reviewers",
		workspace = pr.workspace,
		repo = pr.repo,
		pr_id = pr.id,
	})
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsActivityEntry[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_activity(pr, _opts, on_done) ---@diagnostic disable-line: unused-local
	if pr == nil or pr.workspace == nil or pr.repo == nil or pr.id == nil then
		on_done({}, nil)
		return nil
	end
	local endpoint = string.format(
		"/projects/%s/repos/%s/pull-requests/%s/activities?limit=100",
		pr.workspace,
		pr.repo,
		tostring(pr.id)
	)
	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(mapper.to_activities_list(result), nil)
	end, {
		action = "Bitbucket Server PR activity",
		workspace = pr.workspace,
		repo = pr.repo,
		pr_id = pr.id,
	})
end

---@param pr PullRequest
---@param on_done fun(builds: PullsBuild[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_builds(pr, on_done)
	local commit = pr and pr.source and pr.source.commit_hash or ""
	if commit == "" then
		on_done({}, nil)
		return nil
	end

	local full_url = service.server_url("/rest/build-status/1.0", "/commits/" .. commit)

	return service.request("GET", full_url, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		---@type PullsBuild[]
		local builds = {}
		for _, item in ipairs((type(result) == "table" and result.values) or {}) do
			local b = type(item) == "table" and item or {}
			table.insert(builds, {
				name = tostring(b.name or b.key or ""),
				state = tostring(b.state or ""):upper(),
				url = tostring(b.url or ""),
				key = tostring(b.key or ""),
			})
		end

		on_done(builds, nil)
	end, {
		action = "Bitbucket Server build statuses",
		commit = commit,
	})
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(commits: PullsCommit[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_commits(pr, opts, on_done)
	if pr == nil or pr.workspace == nil or pr.repo == nil or pr.id == nil then
		on_done({}, nil)
		return nil
	end
	local force = (opts or {}).force_refresh == true
	local endpoint =
		string.format("/projects/%s/repos/%s/pull-requests/%s/commits?limit=50", pr.workspace, pr.repo, tostring(pr.id))
	local key = "bitbucket-server:pr:commits:" .. endpoint
	if not force then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end
	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local commits = mapper.to_commits_list(result)
		for _, c in ipairs(commits) do
			if c.hash ~= "" then
				c.statuses_url = service.server_url("/rest/build-status/1.0", "/commits/" .. c.hash)
			end
		end
		service.set_cache(key, commits, service.cache_ttl())
		on_done(commits, nil)
	end, {
		action = "Bitbucket Server PR commits",
		workspace = pr.workspace,
		repo = pr.repo,
		pr_id = pr.id,
	})
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_diffstat(pr, _opts, on_done) ---@diagnostic disable-line: unused-local
	if pr == nil or pr.workspace == nil or pr.repo == nil or pr.id == nil then
		on_done({}, nil)
		return nil
	end
	local endpoint = string.format(
		"/projects/%s/repos/%s/pull-requests/%s/changes?limit=500",
		pr.workspace,
		pr.repo,
		tostring(pr.id)
	)
	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(mapper.to_diffstat_list(result), nil)
	end, {
		action = "Bitbucket Server PR diffstat",
		workspace = pr.workspace,
		repo = pr.repo,
		pr_id = pr.id,
	})
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(files: DiffFile[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_diff(pr, _opts, on_done) ---@diagnostic disable-line: unused-local
	if pr == nil or pr.workspace == nil or pr.repo == nil or pr.id == nil then
		on_done({}, nil)
		return nil
	end
	local endpoint =
		string.format("/projects/%s/repos/%s/pull-requests/%s/diff", pr.workspace, pr.repo, tostring(pr.id))
	local diff_parser = require("atlas.core.git.diff_parser")
	return service.request_text("GET", endpoint, { Accept = "text/plain" }, nil, function(text, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(diff_parser.parse(text or ""), nil)
	end, {
		action = "Bitbucket Server PR diff",
		workspace = pr.workspace,
		repo = pr.repo,
		pr_id = pr.id,
	})
end

---@param values table[]
---@return string status, string|nil url
local function aggregate_statuses(values)
	if #values == 0 then
		return "unknown", nil
	end
	local has_failed, has_inprogress, has_cancelled, has_success = false, false, false, false
	local first_url
	for _, item in ipairs(values) do
		local s = tostring(item.state or ""):upper()
		if not first_url and item.url and item.url ~= "" then
			first_url = tostring(item.url)
		end
		if s == "FAILED" then
			has_failed = true
		elseif s == "INPROGRESS" then
			has_inprogress = true
		elseif s == "CANCELLED" then
			has_cancelled = true
		elseif s == "SUCCESSFUL" then
			has_success = true
		end
	end
	local status = "unknown"
	if has_failed then
		status = "failed"
	elseif has_inprogress then
		status = "inprogress"
	elseif has_cancelled then
		status = "stopped"
	elseif has_success then
		status = "successful"
	end
	return status, first_url
end

---@param statuses_url string
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(status: string|nil, url: string|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_commit_status(statuses_url, opts, on_done)
	if type(statuses_url) ~= "string" or statuses_url == "" then
		on_done("unknown", nil, nil)
		return nil
	end
	local force = (opts or {}).force_refresh == true
	local key = "bitbucket-server:commit:statuses:" .. statuses_url
	if not force then
		local cached, ok = service.get_cache(key)
		if ok then
			local values = (cached or {}).values or cached or {}
			local s, u = aggregate_statuses(values)
			on_done(s, u, nil)
			return nil
		end
	end
	return service.request("GET", statuses_url, nil, nil, function(result, err)
		if err then
			on_done(nil, nil, err)
			return
		end
		service.set_cache(key, result, service.cache_ttl())
		local values = (type(result) == "table" and result.values) or {}
		local s, u = aggregate_statuses(values)
		on_done(s, u, nil)
	end, { action = "Bitbucket Server commit status" })
end

---@param pr PullRequest
---@param on_done fun(result: table|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.approve(pr, on_done)
	local approve_url = pr_link(pr, "approve")
	if approve_url == "" then
		on_done(nil, "No approve URL available")
		return nil
	end
	return service.request("POST", approve_url, nil, nil, on_done, { action = "Bitbucket Server approve" })
end

---@param pr PullRequest
---@param on_done fun(result: table|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.unapprove(pr, on_done)
	local participant_url = pr_link(pr, "request_changes")
	if participant_url == "" then
		on_done(nil, "No participant URL available")
		return nil
	end
	local body = vim.json.encode({ status = "UNAPPROVED" })
	return service.request("PUT", participant_url, nil, body, on_done, { action = "Bitbucket Server unapprove" })
end

---@param pr PullRequest
---@param on_done fun(result: table|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.request_changes(pr, on_done)
	local request_changes_url = pr_link(pr, "request_changes")
	if request_changes_url == "" then
		on_done(nil, "No request changes URL available")
		return nil
	end
	local body = vim.json.encode({ status = "NEEDS_WORK" })
	return service.request("PUT", request_changes_url, nil, body, on_done, {
		action = "Bitbucket Server request changes",
	})
end

---@param pr PullRequest
---@param _opts { message?: string, close_source_branch?: boolean, merge_strategy?: string }|nil
---@param on_done fun(result: table|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.merge(pr, _opts, on_done) ---@diagnostic disable-line: unused-local
	local merge_url = pr_link(pr, "merge")
	if merge_url == "" then
		on_done(nil, "No merge URL available")
		return nil
	end
	return service.request("POST", merge_url, nil, nil, on_done, { action = "Bitbucket Server merge" })
end

---@param branch any
---@return string  "refs/heads/<name>" form, ready for Server APIs
local function refs_heads(branch)
	local s = tostring(branch or "")
	if s == "" then
		return ""
	end
	if s:sub(1, 5) == "refs/" then
		return s
	end
	return "refs/heads/" .. s
end

---@param opts PullsCreatePROpts
---@param on_done fun(result: PullsCreatePRResult|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.create_pr(opts, on_done)
	local slug = service.normalize_server_repo_slug(opts.repo_slug)
	local project, repo = slug:match("^([^/]+)/(.+)$")
	if project == nil or repo == nil then
		vim.schedule(function()
			on_done(nil, "Invalid repo slug; expected project/repo")
		end)
		return nil
	end

	local repo_ref = { slug = repo, project = { key = project } }
	local payload = {
		title = opts.title,
		description = opts.body or "",
		fromRef = { id = refs_heads(opts.head), repository = repo_ref },
		toRef = { id = refs_heads(opts.base), repository = repo_ref },
	}
	if opts.reviewers and #opts.reviewers > 0 then
		local list = {}
		for _, r in ipairs(opts.reviewers) do
			local name = tostring(r.provider_id or "")
			if name ~= "" then
				table.insert(list, { user = { name = name } })
			end
		end
		payload.reviewers = list
	end

	local endpoint = string.format("/projects/%s/repos/%s/pull-requests", project, repo)
	return service.request("POST", endpoint, nil, vim.json.encode(payload), function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local id, url
		if type(result) == "table" then
			id = result.id
			local links = type(result.links) == "table" and result.links or {}
			local self_links = type(links.self) == "table" and links.self or {}
			local first = type(self_links[1]) == "table" and self_links[1] or {}
			url = first.href
		end
		on_done({ id = id, url = url, message = "PR created" }, nil)
	end, {
		action = "Bitbucket Server create PR",
		project = project,
		repo = repo,
		head = opts.head,
		base = opts.base,
	})
end

---@param opts { repo_slug: string, repo_root: string|nil, head: string, base: string }
---@param on_done fun(reviewers: PullsCreatePRReviewer[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_default_reviewers(opts, on_done)
	local slug = service.normalize_server_repo_slug(opts.repo_slug)
	local project, repo = slug:match("^([^/]+)/(.+)$")
	if project == nil or repo == nil then
		vim.schedule(function()
			on_done(nil, "Invalid repo slug; expected project/repo")
		end)
		return nil
	end

	local url = service.server_url(
		"/rest/default-reviewers/1.0",
		string.format("/projects/%s/repos/%s/conditions", project, repo)
	)
	return service.request("GET", url, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		---@type table<string, true>
		local seen = {}
		---@type PullsCreatePRReviewer[]
		local items = {}
		for _, cond in ipairs(type(result) == "table" and result or {}) do
			for _, user in ipairs((type(cond) == "table" and cond.reviewers) or {}) do
				local name = type(user) == "table" and tostring(user.name or user.slug or "") or ""
				if name ~= "" and not seen[name] then
					seen[name] = true
					local display = tostring(user.displayName or name)
					table.insert(items, {
						label = "@" .. (user.slug or name) .. " (" .. display .. ")",
						provider_id = name,
						selected = true,
						default = true,
					})
				end
			end
		end
		on_done(items, nil)
	end, {
		action = "Bitbucket Server default reviewers",
		project = project,
		repo = repo,
	})
end

return M
