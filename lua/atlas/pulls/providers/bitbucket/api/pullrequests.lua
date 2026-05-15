local M = {}

local service = require("atlas.pulls.providers.bitbucket.api.service")
local mapper = require("atlas.pulls.providers.bitbucket.api.mapper")
local cache = require("atlas.core.cache")
local logger = require("atlas.core.logger")
local http = require("atlas.core.http")
local state = require("atlas.pulls.providers.bitbucket.state")

---@param workspace string
---@param repo string
---@return string
local function cache_key(workspace, repo, statuses)
	local sorted = vim.deepcopy(statuses)
	table.sort(sorted)
	return string.format("bitbucket:prs:%s/%s:%s", workspace, repo, table.concat(sorted, ","))
end

---@param workspace string
---@param repo string
---@param opts { user: string, token: string, cache_ttl: number, force: boolean, pagelen: number|nil, statuses: string[]|nil }
---@param on_done fun(prs: PullRequest[], err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
local function fetch_pullrequests_single(workspace, repo, opts, on_done)
	local statuses_for_key = opts.statuses or { state.pr_state }
	local key = cache_key(workspace, repo, statuses_for_key)
	if not opts.force then
		local cached = cache.get(key)
		if cached and cached.value then
			logger.loginfo("Bitbucket cache hit", { workspace = workspace, repo = repo })
			on_done(cached.value, nil)
			return nil
		end
	end

	logger.loginfo("Fetching pull requests", {
		workspace = workspace,
		repo = repo,
	})

	local statuses = opts.statuses or { state.pr_state }
	local state_params = {}
	for _, s in ipairs(statuses) do
		table.insert(state_params, "state=" .. s)
	end
	local endpoint = string.format(
		"/repositories/%s/%s/pullrequests?%s&pagelen=%d",
		workspace,
		repo,
		table.concat(state_params, "&"),
		tonumber(opts.pagelen) or 50
	)
	local user, token, _ = service.get_auth()
	local headers = service.build_headers(user, token)

	return http.curl_request("GET", service.url(endpoint), headers, nil, function(result, err)
		if err then
			logger.logerror("Bitbucket PR fetch failed", {
				workspace = workspace,
				repo = repo,
				error = err,
			})
			on_done({}, err)
			return
		end

		if type(result) ~= "table" then
			logger.logerror("Bitbucket PR fetch invalid response", {
				workspace = workspace,
				repo = repo,
			})
			on_done({}, "Bitbucket response is not a JSON object")
			return
		end

		local api_err = service.api_error_message(result)
		if api_err then
			logger.logerror("Bitbucket PR fetch API error", {
				workspace = workspace,
				repo = repo,
				error = api_err,
			})
			on_done({}, api_err)
			return
		end

		local normalized = mapper.to_pull_requests_list(result, workspace, repo)
		cache.set(key, normalized, opts.cache_ttl)
		logger.loginfo("Fetch success", {
			workspace = workspace,
			repo = repo,
			pr_count = #normalized,
			cached = true,
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

	logger.loginfo("Bitbucket batch fetch start", {
		repo_count = #view_repos,
	})

	local ttl = service.cache_ttl()
	local user, token, auth_err = service.get_auth()
	if auth_err then
		logger.logerror("Bitbucket auth missing", { error = auth_err })
		vim.notify("Atlas Bitbucket: " .. auth_err, vim.log.levels.ERROR)
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

			logger.loginfo("Bitbucket batch fetch completed", {
				repo_count = #view_repos,
				pr_count = #all_prs,
				error_count = #errors,
			})
			local groups = mapper.to_pull_request_groups(all_prs)
			if #errors > 0 then
				on_done(groups, errors)
			else
				on_done(groups, nil)
			end
		end
	end

	for _, repo in ipairs(view_repos) do
		local handle = fetch_pullrequests_single(repo.workspace, repo.repo, {
			user = user,
			token = token,
			cache_ttl = ttl,
			force = opts.force_load,
			pagelen = opts.pagelen,
			statuses = opts.statuses,
		}, finish)
		if handle ~= nil then
			table.insert(handles, handle)
		end
	end

	return {
		cancel = cancel_all,
	}
end

---@param workspace string
---@param repo string
---@param pr_id string|number
---@param opts? { force_load?: boolean }
---@param on_done fun(detail: PullRequest|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_pullrequest(workspace, repo, pr_id, opts, on_done)
	opts = opts or {}

	local key = string.format("bitbucket:pr:detail:%s/%s/%s", workspace, repo, tostring(pr_id))
	if opts.force_load ~= true then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/repositories/%s/%s/pullrequests/%s", workspace, repo, tostring(pr_id))
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
	end)
end

---@param merge_url string
---@param opts { message?: string, close_source_branch?: boolean, merge_strategy?: string }|nil
---@param on_done fun(result: table|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.merge(merge_url, opts, on_done)
	opts = opts or {}
	local payload = {}
	if opts.close_source_branch ~= nil then
		payload.close_source_branch = opts.close_source_branch == true
	end
	if type(opts.merge_strategy) == "string" and opts.merge_strategy ~= "" then
		payload.merge_strategy = opts.merge_strategy
	end
	if type(opts.message) == "string" and opts.message ~= "" then
		payload.message = opts.message
	end

	local body = vim.fn.empty(payload) == 1 and nil or vim.json.encode(payload)
	return service.request("POST", merge_url, nil, body, on_done)
end

---@param approve_url string
---@param on_done fun(result: table|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.approve(approve_url, on_done)
	return service.request("POST", approve_url, nil, nil, on_done)
end

---@param request_changes_url string
---@param on_done fun(result: table|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.request_changes(request_changes_url, on_done)
	return service.request("POST", request_changes_url, nil, nil, on_done)
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewers(pr, _opts, on_done)
	local raw = pr._raw or {}
	local self_url = tostring((raw.links or {}).self or "")
	if self_url == "" then
		on_done(nil, "No PR self link available")
		return nil
	end

	return service.request("GET", self_url, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		---@type PullsReviewer[]
		local reviewers = {}
		for _, item in ipairs((result or {}).participants or {}) do
			local p = type(item) == "table" and item or {}
			local user = type(p.user) == "table" and p.user or {}
			if tostring(p.role or ""):upper() == "REVIEWER" then
				local decision = "pending"
				local s = tostring(p.state or "")
				if s == "approved" then
					decision = "approved"
				elseif s == "changes_requested" then
					decision = "changes_requested"
				end
				table.insert(reviewers, {
					name = tostring(user.display_name or ""),
					nickname = tostring(user.nickname or ""),
					decision = decision,
				})
			end
		end

		on_done(reviewers, nil)
	end)
end

---@param pr PullRequest
---@param on_done fun(builds: PullsBuild[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_builds(pr, on_done)
	local raw = pr._raw or {}
	local statuses_url = tostring((raw.links or {}).statuses or "")
	if statuses_url == "" then
		on_done({}, nil)
		return nil
	end

	return service.request("GET", statuses_url, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		---@type PullsBuild[]
		local builds = {}
		for _, item in ipairs((result or {}).values or {}) do
			local b = type(item) == "table" and item or {}
			table.insert(builds, {
				name = tostring(b.name or b.key or ""),
				state = tostring(b.state or ""):upper(),
				url = tostring(b.url or ""),
				key = tostring(b.key or ""),
			})
		end

		on_done(builds, nil)
	end)
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(pr, _opts, on_done)
	local raw = pr._raw or {}
	local activity_url = tostring((raw.links or {}).activity or "")
	if activity_url == "" then
		on_done({}, nil)
		return nil
	end

	return service.request("GET", activity_url, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		on_done(mapper.to_activities_list(result), nil)
	end)
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diffstat(pr, _opts, on_done)
	local raw = pr._raw or {}
	local diffstat_url = tostring((raw.links or {}).diffstat or "")
	if diffstat_url == "" then
		on_done({}, nil)
		return nil
	end

	return service.request("GET", diffstat_url, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		---@type PullsDiffstatEntry[]
		local entries = {}
		for _, item in ipairs((result or {}).values or {}) do
			local d = type(item) == "table" and item or {}
			local new_file = type(d.new) == "table" and d.new or {}
			local old_file = type(d.old) == "table" and d.old or {}
			local status = tostring(d.status or ""):lower()
			if status == "" then
				status = "modified"
			end

			table.insert(entries, {
				status = status,
				path = tostring(new_file.path or old_file.path or ""),
				old_path = old_file.path and tostring(old_file.path) or nil,
				lines_added = tonumber(d.lines_added) or 0,
				lines_removed = tonumber(d.lines_removed) or 0,
			})
		end

		on_done(entries, nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(commits: PullsCommit[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commits(pr, opts, on_done)
	local raw = pr._raw or {}
	local commits_url = tostring((raw.links or {}).commits or "")
	if commits_url == "" then
		on_done({}, nil)
		return nil
	end

	local force = (opts or {}).force_refresh == true
	local sep = commits_url:find("?") and "&" or "?"
	local url = string.format("%s%spagelen=%d", commits_url, sep, 50)
	local key = "bitbucket:pr:commits:" .. url
	if not force then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.request("GET", url, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local commits = mapper.to_commits_list(result)
		service.set_cache(key, commits, service.cache_ttl())
		on_done(commits, nil)
	end)
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(files: DiffFile[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diff(pr, _opts, on_done)
	local raw = pr._raw or {}
	local diff_url = tostring((raw.links or {}).diff or "")
	if diff_url == "" then
		on_done({}, nil)
		return nil
	end

	local diff_parser = require("atlas.core.git.diff_parser")
	return service.request_text("GET", diff_url, nil, nil, function(text, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(diff_parser.parse(text or ""), nil)
	end)
end

---@param statuses_url string
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(status: string|nil, url: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commit_status(statuses_url, opts, on_done)
	if type(statuses_url) ~= "string" or statuses_url == "" then
		on_done("unknown", nil, nil)
		return nil
	end

	local force = (opts or {}).force_refresh == true
	local sep = statuses_url:find("?") and "&" or "?"
	local url = string.format("%s%spagelen=%d", statuses_url, sep, 30)
	local key = "bitbucket:commit:statuses:" .. url
	if not force then
		local cached, ok = service.get_cache(key)
		if ok then
			local entries = (cached or {}).values or cached or {}
			local agg_status, first_url = M._aggregate_statuses(entries)
			on_done(agg_status, first_url, nil)
			return nil
		end
	end

	return service.request("GET", url, nil, nil, function(result, err)
		if err then
			on_done(nil, nil, err)
			return
		end

		service.set_cache(key, result, service.cache_ttl())
		local values = (result or {}).values or {}
		local agg_status, first_url = M._aggregate_statuses(values)
		on_done(agg_status, first_url, nil)
	end)
end

---@param opts PullsCreatePROpts
---@param on_done fun(result: PullsCreatePRResult|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.create_pr(opts, on_done)
	local slug = tostring(opts.repo_slug or "")
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	local workspace, repo = slug:match("^([^/]+)/(.+)$")
	if workspace == nil or repo == nil then
		vim.schedule(function()
			on_done(nil, "Invalid repo slug; expected workspace/repo")
		end)
		return nil
	end

	local payload = {
		title = opts.title,
		description = opts.body or "",
		source = { branch = { name = opts.head } },
		destination = { branch = { name = opts.base } },
		close_source_branch = true,
		draft = opts.draft == true,
	}

	if opts.reviewers and #opts.reviewers > 0 then
		local list = {}
		for _, reviewer in ipairs(opts.reviewers) do
			table.insert(list, { uuid = reviewer.provider_id })
		end
		payload.reviewers = list
	end

	local endpoint = string.format("/repositories/%s/%s/pullrequests", workspace, repo)
	return service.request("POST", endpoint, nil, vim.json.encode(payload), function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local id = nil
		local url = nil
		if type(result) == "table" then
			id = result.id
			if type(result.links) == "table" and type(result.links.html) == "table" then
				url = result.links.html.href
			end
		end

		on_done({ id = id, url = url, message = "PR created" }, nil)
	end, {
		action = "Create PR",
		workspace = workspace,
		repo = repo,
		head = opts.head,
		base = opts.base,
		draft = opts.draft == true,
	})
end

---@param opts { repo_slug: string }
---@param on_done fun(reviewers: PullsCreatePRReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_default_reviewers(opts, on_done)
	local slug = tostring(opts.repo_slug or "")
	local workspace, repo = slug:match("^([^/]+)/(.+)$")
	if workspace == nil or repo == nil then
		vim.schedule(function()
			on_done(nil, "Invalid repo slug; expected workspace/repo")
		end)
		return nil
	end

	local endpoint = string.format("/repositories/%s/%s/effective-default-reviewers", workspace, repo)
	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local items = {}
		local values = type(result) == "table" and type(result.values) == "table" and result.values or {}
		for _, entry in ipairs(values) do
			local user = type(entry) == "table" and type(entry.user) == "table" and entry.user or nil
			local uuid = user and tostring(user.uuid or "") or ""
			if user and uuid ~= "" then
				local nickname = tostring(user.nickname or "")
				local display = tostring(user.display_name or "")
				local label = nickname ~= "" and ("@" .. nickname)
					or (display ~= "" and ("@" .. display) or ("@" .. uuid))
				table.insert(items, {
					label = label,
					provider_id = uuid,
					selected = true,
					default = true,
				})
			end
		end

		on_done(items, nil)
	end)
end

---@param values table[]
---@return string status
---@return string|nil url
function M._aggregate_statuses(values)
	if #values == 0 then
		return "unknown", nil
	end

	local has_failed = false
	local has_inprogress = false
	local has_stopped = false
	local has_success = false
	local first_url = nil

	for _, item in ipairs(values) do
		local s = tostring(item.state or ""):upper()
		if not first_url and item.url and item.url ~= "" then
			first_url = tostring(item.url)
		end
		if s == "FAILED" then
			has_failed = true
		elseif s == "INPROGRESS" then
			has_inprogress = true
		elseif s == "STOPPED" then
			has_stopped = true
		elseif s == "SUCCESSFUL" then
			has_success = true
		end
	end

	local status = "unknown"
	if has_failed then
		status = "failed"
	elseif has_inprogress then
		status = "inprogress"
	elseif has_stopped then
		status = "stopped"
	elseif has_success then
		status = "successful"
	end

	return status, first_url
end

return M
