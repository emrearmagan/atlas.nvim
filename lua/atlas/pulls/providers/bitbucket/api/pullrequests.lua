local M = {}

local config = require("atlas.config")
local service = require("atlas.pulls.providers.bitbucket.api.service")
local mapper = require("atlas.pulls.providers.bitbucket.api.mapper")
local logger = require("atlas.core.logger")
local state = require("atlas.pulls.providers.bitbucket.state")

---@param pr PullRequest
---@param key string
---@return string
local function pr_link(pr, key)
	return tostring((pr._raw.links or {})[key] or "")
end

---@param pr PullRequest
---@param action "merge"|"decline"
---@return boolean
function M.has_action(pr, action)
	return pr_link(pr, action) ~= ""
end

---@param workspace string
---@param repo string
---@param statuses string[]
---@param pagelen integer
---@return string
local function cache_key(workspace, repo, statuses, pagelen)
	local sorted = vim.deepcopy(statuses)
	table.sort(sorted)
	return string.format("bitbucket:prs:%s/%s:%s:pagelen:%d", workspace, repo, table.concat(sorted, ","), pagelen)
end

---@param workspace string
---@param repo string
---@param opts { cache_ttl: number, force: boolean, pagelen: number|nil, statuses: string[]|nil }
---@param on_done fun(prs: PullRequest[], err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
local function fetch_pullrequests_single(workspace, repo, opts, on_done)
	local statuses_for_key = opts.statuses or { state.pr_state }
	local pagelen = tonumber(opts.pagelen) or 50
	local key = cache_key(workspace, repo, statuses_for_key, pagelen)
	if not opts.force then
		local cached, ok = service.get_persistent_cache(key)
		if ok then
			logger.loginfo("Bitbucket cache hit", { workspace = workspace, repo = repo })
			on_done(cached, nil)
			return nil
		end
	end

	local statuses = opts.statuses or { state.pr_state }
	local state_params = {}
	for _, s in ipairs(statuses) do
		table.insert(state_params, "state=" .. s)
	end
	local endpoint = string.format(
		"/repositories/%s/%s/pullrequests?%s&pagelen=%d&fields=%%2Bvalues.participants",
		workspace,
		repo,
		table.concat(state_params, "&"),
		pagelen
	)
	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err then
			on_done({}, err)
			return
		end

		local normalized = mapper.to_pull_requests_list(result, workspace, repo)
		service.set_persistent_cache(key, normalized, opts.cache_ttl)
		logger.loginfo("Fetch success", {
			workspace = workspace,
			repo = repo,
			pr_count = #normalized,
			cached = true,
		})

		on_done(normalized, nil)
	end, { action = "Fetching pull requests", workspace = workspace, repo = repo })
end

---@param view_repos AtlasBitbucketRepoTarget[]
---@param opts { force_load: boolean, pagelen: number|nil, statuses: string[]|nil }
---@param on_done fun(pulls: PullRequest[], err: string[]|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequests(view_repos, opts, on_done)
	local MAX_CONCURRENT_REQUESTS = 8
	if view_repos == nil or #view_repos == 0 then
		on_done({}, nil)
		return nil
	end

	logger.loginfo("Bitbucket batch fetch start", {
		repo_count = #view_repos,
	})

	local ttl = service.cache_ttl()
	local _, _, auth_err = service.get_auth()
	if auth_err then
		logger.logerror("Bitbucket auth missing", { error = auth_err })
		on_done({}, { tostring(auth_err) })
		return nil
	end

	local pending = #view_repos
	local next_index = 1
	local active = 0
	local done = false
	local pumping = false
	local results = {}
	local errors = {}
	local handles = {}

	local function cancel_all()
		done = true
		for _, handle in pairs(handles) do
			if handle and handle.cancel then
				pcall(handle.cancel)
			end
		end
		handles = {}
	end

	local pump

	local function finish(index, prs, err)
		if done then
			return
		end

		handles[index] = nil
		active = active - 1
		if err then
			table.insert(errors, tostring(err))
		end

		results[index] = prs or {}

		pending = pending - 1
		if pending == 0 then
			done = true
			local all_prs = {}
			for result_index = 1, #view_repos do
				vim.list_extend(all_prs, results[result_index])
			end

			logger.loginfo("Bitbucket batch fetch completed", {
				repo_count = #view_repos,
				pr_count = #all_prs,
				error_count = #errors,
			})
			if #errors > 0 then
				on_done(all_prs, errors)
			else
				on_done(all_prs, nil)
			end
			return
		end

		pump()
	end

	pump = function()
		if done or pumping then
			return
		end
		pumping = true
		while not done and active < MAX_CONCURRENT_REQUESTS and next_index <= #view_repos do
			local index = next_index
			local repo = view_repos[index]
			next_index = next_index + 1
			active = active + 1
			local completed = false
			local handle = fetch_pullrequests_single(repo.workspace, repo.repo, {
				cache_ttl = ttl,
				force = opts.force_load,
				pagelen = opts.pagelen,
				statuses = opts.statuses,
			}, function(prs, err)
				completed = true
				finish(index, prs, err)
			end)
			if handle ~= nil and not completed and not done then
				handles[index] = handle
			end
		end
		pumping = false
	end

	pump()

	return {
		cancel = cancel_all,
	}
end

---@param pr PullRequestRef
---@param opts? { force_load?: boolean }
---@param on_done fun(detail: PullRequest|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_pullrequest(pr, opts, on_done)
	opts = opts or {}
	local workspace, repo = pr.repo_full_name:match("^([^/]+)/(.+)$")
	if workspace == nil or repo == nil then
		on_done(nil, "PR missing workspace/repo info")
		return nil
	end

	local key = string.format("bitbucket:pr:detail:%s/%s/%s", workspace, repo, tostring(pr.id))
	if opts.force_load ~= true then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/repositories/%s/%s/pullrequests/%s", workspace, repo, tostring(pr.id))
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

---@param pr PullRequest
---@param fields table
---@param on_done fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
local function update_pullrequest(pr, fields, on_done)
	local url = pr_link(pr, "self")
	if url == "" then
		on_done(false, "No pull request URL available")
		return nil
	end

	return service.request("PUT", url, nil, vim.json.encode(fields), function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.clear_cache()
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param title string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.update_title(pr, title, on_done)
	return update_pullrequest(pr, { title = title }, on_done)
end

---@param pr PullRequest
---@param description string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.update_description(pr, description, on_done)
	return update_pullrequest(pr, { description = description }, on_done)
end

---@param pr PullRequest
---@param draft boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.set_draft(pr, draft, on_done)
	return update_pullrequest(pr, { draft = draft }, on_done)
end

---@param pr PullRequest
---@param opts { message?: string, close_source_branch?: boolean, merge_strategy?: string }|nil
---@param on_done fun(result: table|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.merge(pr, opts, on_done)
	local merge_url = pr_link(pr, "merge")
	if merge_url == "" then
		on_done(nil, "No merge URL available")
		return nil
	end
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

	local body = next(payload) == nil and nil or vim.json.encode(payload)
	return service.request("POST", merge_url, nil, body, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		service.clear_cache()
		on_done(result, nil)
	end)
end

---@param pr PullRequest
---@param on_done fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.decline(pr, on_done)
	local url = pr_link(pr, "decline")
	if url == "" then
		on_done(false, "No decline URL available")
		return nil
	end
	return service.request("POST", url, nil, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.clear_cache()
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param on_done fun(participants: table[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_participants(pr, on_done)
	local raw = pr._raw
	local self_url = tostring((raw.links or {}).self or "")
	if self_url == "" then
		on_done(nil, "No PR self link available")
		return nil
	end
	local sep = self_url:find("?") and "&" or "?"
	local url = string.format("%s%sfields=participants", self_url, sep)

	return service.request("GET", url, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done((result or {}).participants, nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewers(pr, opts, on_done)
	if not (opts or {}).force_refresh and pr.reviewers ~= nil then
		on_done(pr.reviewers, nil)
		return nil
	end

	return fetch_participants(pr, function(participants, err)
		if err then
			on_done(nil, err)
			return
		end
		pr.reviewers = mapper.to_reviewers(participants)
		pr.review_decisions = mapper.to_review_decisions(participants)
		on_done(pr.reviewers, nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_review_participants(pr, opts, on_done)
	local self_url = tostring(((pr._raw or {}).links or {}).self or "")
	local key = "bitbucket:pr:review-participants:" .. self_url
	if not (opts or {}).force_refresh then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return fetch_participants(pr, function(participants, err)
		if err then
			on_done(nil, err)
			return
		end
		local reviewers = mapper.to_reviewers(participants)
		vim.list_extend(reviewers, mapper.to_review_decisions(participants))
		service.set_cache(key, reviewers)
		on_done(reviewers, nil)
	end)
end

---@param pr PullRequest
---@param selected PullsCreatePRReviewer[]
---@param _original PullsCreatePRReviewer[]
---@param on_done fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.update_reviewers(pr, selected, _original, on_done)
	local reviewers = {}
	for _, reviewer in ipairs(selected) do
		table.insert(reviewers, { uuid = reviewer.provider_id })
	end
	return update_pullrequest(pr, { reviewers = reviewers }, on_done)
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
		close_source_branch = config.options.pulls.default_delete_branch == true,
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

		service.clear_cache()
		on_done({ id = result.id, url = result.links.html.href, message = "PR created" }, nil)
	end, {
		action = "Create PR",
		workspace = workspace,
		repo = repo,
		head = opts.head,
		base = opts.base,
		draft = opts.draft == true,
	})
end

---@param opts { repo_slug: string, repo_root: string|nil, head: string, base: string, pr: PullRequest|nil }
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

		local selected = {}
		local current = {}
		for _, reviewer in ipairs((opts.pr and opts.pr.reviewers) or {}) do
			local id = tostring(reviewer.provider_id or "")
			if id ~= "" then
				selected[id] = true
				current[id] = reviewer
			end
		end

		local reviewers = {}
		local found = {}
		local values = result.values or {}
		for _, entry in ipairs(values) do
			local user = entry.user
			local uuid = tostring(user.uuid or "")
			if uuid ~= "" then
				found[uuid] = true
				local nickname = tostring(user.nickname or "")
				local name = tostring(user.display_name or "")
				local is_selected = opts.pr == nil or selected[uuid] == true
				table.insert(reviewers, {
					label = nickname ~= "" and ("@" .. nickname) or (name ~= "" and name or uuid),
					provider_id = uuid,
					selected = is_selected,
					default = true,
				})
			end
		end

		for uuid, reviewer in pairs(current) do
			if not found[uuid] then
				local nickname = tostring(reviewer.nickname or reviewer.username or "")
				local name = tostring(reviewer.name or "")
				table.insert(reviewers, {
					label = nickname ~= "" and ("@" .. nickname) or (name ~= "" and name or uuid),
					provider_id = uuid,
					selected = true,
				})
			end
		end

		on_done(reviewers, nil)
	end)
end

return M
