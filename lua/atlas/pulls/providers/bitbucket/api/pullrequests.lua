local M = {}

local config = require("atlas.config")
local json = require("atlas.core.json")
local service = require("atlas.pulls.providers.bitbucket.api.service")
local mapper = require("atlas.pulls.providers.bitbucket.api.mapper")
local logger = require("atlas.core.logger")
local request_scope = require("atlas.core.requests")
local repositories_api = require("atlas.pulls.providers.bitbucket.api.repositories")
local url_encode = require("atlas.core.utils").url_encode

local SUMMARY_FIELDS = {
	"id",
	"title",
	"state",
	"draft",
	"author",
	"source",
	"destination",
	"comment_count",
	"task_count",
	"created_on",
	"updated_on",
	"participants",
	"links",
}
local PULL_REQUEST_FIELDS = table.concat(SUMMARY_FIELDS, ",")
local list_fields = {}
for _, field in ipairs(SUMMARY_FIELDS) do
	table.insert(list_fields, "values." .. field)
end
local PULL_REQUEST_LIST_FIELDS = table.concat(list_fields, ",")

---@param pagelen integer
---@param query string
---@return string
local function build_query(pagelen, query)
	local parts = {
		"fields=" .. url_encode(PULL_REQUEST_LIST_FIELDS),
		"pagelen=" .. tostring(pagelen),
		"q=" .. url_encode(query),
	}
	table.sort(parts)
	return table.concat(parts, "&")
end

---@param pr PullRequest
---@param action "merge"|"decline"
---@return boolean
function M.has_action(pr, action)
	---@cast pr BitbucketPullRequest
	return tostring(pr.links[action] or "") ~= ""
end

---@param workspace string
---@param repo string
---@param opts { cache_ttl: number, force_refresh: boolean, pagelen: number, query: string }
---@param on_done fun(prs: PullRequest[], err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
local function fetch_pullrequests_single(workspace, repo, opts, on_done)
	local query = build_query(opts.pagelen, opts.query)
	local key = string.format("bitbucket:prs:%s/%s:%s", workspace, repo, query)
	if not opts.force_refresh then
		local cached, ok = service.get_persistent_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/repositories/%s/%s/pullrequests?%s", workspace, repo, query)
	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err then
			on_done({}, err)
			return
		end

		local normalized = mapper.to_pull_requests_list(result, workspace, repo)
		service.set_persistent_cache(key, normalized, opts.cache_ttl)
		on_done(normalized, nil)
	end, { action = "Fetch pull requests", workspace = workspace, repo = repo })
end

---@param repos BitbucketRepoTarget[]
---@param opts { force_refresh: boolean, pagelen: number, query: string }
---@param on_done fun(pulls: PullRequest[], err: string[]|nil)
---@return { cancel: fun() }|nil
function M.fetch_for_repositories(repos, opts, on_done)
	if #repos == 0 then
		on_done({}, nil)
		return nil
	end

	local ttl = service.cache_ttl()
	local _, _, auth_err = service.get_auth()
	if auth_err then
		logger.logerror("Fetch pull requests failed", { repo_count = #repos, error = auth_err })
		on_done({}, { tostring(auth_err) })
		return nil
	end

	local requests = request_scope.new()
	local starts = {}
	for index, repo_ref in ipairs(repos) do
		local repo = repo_ref
		starts[index] = function(done)
			return fetch_pullrequests_single(repo.workspace, repo.repo, {
				cache_ttl = ttl,
				force_refresh = opts.force_refresh,
				pagelen = opts.pagelen,
				query = opts.query,
			}, done)
		end
	end

	requests.all(starts, function(results, request_errors)
		local pulls, errors = {}, {}
		for index = 1, #repos do
			if results[index] then
				vim.list_extend(pulls, results[index])
			end
			if request_errors[index] then
				table.insert(errors, request_errors[index])
			end
		end
		table.sort(pulls, function(left, right)
			return left.updated_on > right.updated_on
		end)
		on_done(pulls, #errors > 0 and errors or nil)
	end)

	return requests
end

---@param targets BitbucketPullTarget[]
---@param opts { force_refresh: boolean, pagelen: number, query: string }
---@param on_done fun(pulls: PullRequest[], err: string[]|nil)
---@return { cancel: fun() }|nil
function M.fetch_for_targets(targets, opts, on_done)
	local requests = request_scope.new()
	requests.run(function(done)
		return repositories_api.resolve_targets(targets, opts, done)
	end, function(repos, errors)
		requests.run(function(done)
			return M.fetch_for_repositories(repos, opts, done)
		end, function(pulls, fetch_errors)
			vim.list_extend(errors, fetch_errors or {})
			on_done(pulls, #errors > 0 and errors or nil)
		end)
	end)
	return requests
end

---@param refs PullRequestRef[]
---@param _opts PullsFetchOpts
---@param on_done fun(pulls: PullRequest[], err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_by_refs(refs, _opts, on_done)
	if #refs == 0 then
		on_done({}, nil)
		return nil
	end

	local parsed = {}
	for index, ref in ipairs(refs) do
		local workspace, repo = tostring(ref.repo_full_name or ""):match("^([^/]+)/(.+)$")
		if workspace == nil or repo == nil then
			on_done({}, "PR missing workspace/repo info")
			return nil
		end
		parsed[index] = { ref = ref, workspace = workspace, repo = repo }
	end

	local requests = request_scope.new()
	local starts = {}
	for index, item in ipairs(parsed) do
		starts[index] = function(done)
			local endpoint = string.format(
				"/repositories/%s/%s/pullrequests/%s?fields=%s",
				item.workspace,
				item.repo,
				tostring(item.ref.id),
				PULL_REQUEST_FIELDS
			)
			return service.request("GET", endpoint, nil, nil, function(result, err)
				if err then
					done(nil, err)
					return
				end
				local pull = mapper.to_pull_request(result, item.workspace, item.repo)
				done(pull, nil)
			end, { action = "Fetch pull request", repo = item.ref.repo_full_name, id = item.ref.id })
		end
	end

	requests.all(starts, function(values, errors)
		local pulls = {}
		for index = 1, #parsed do
			if errors[index] then
				on_done({}, errors[index])
				return
			end
			if values[index] then
				table.insert(pulls, values[index])
			end
		end
		on_done(pulls, nil)
	end)
	return requests
end

---@param ref PullRequestRef
---@param opts? { force_refresh?: boolean }
---@param on_done fun(detail: PullRequestDetails|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_pullrequest(ref, opts, on_done)
	opts = opts or {}
	local workspace, repo = ref.repo_full_name:match("^([^/]+)/(.+)$")
	if workspace == nil or repo == nil then
		on_done(nil, "PR missing workspace/repo info")
		return nil
	end

	local key = string.format("bitbucket:pr:detail:%s/%s/%s", workspace, repo, tostring(ref.id))
	if opts.force_refresh ~= true then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format(
		"/repositories/%s/%s/pullrequests/%s?fields=description,close_source_branch",
		workspace,
		repo,
		tostring(ref.id)
	)
	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		---@type BitbucketPullRequestDetails
		local details = {
			description = json.safe_str(result.description) or "",
			close_source_branch = json.nilify(result.close_source_branch),
		}
		service.set_cache(key, details, service.cache_ttl())
		on_done(details, nil)
	end, { action = "Fetch pull request details", repo = ref.repo_full_name, id = ref.id })
end

---@param pr PullRequest
---@param _opts { force_refresh?: boolean }|nil
---@param on_done fun(description: string|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_description(pr, _opts, on_done)
	local workspace, repo = pr.workspace, pr.repo
	if workspace == "" or repo == "" then
		on_done(nil, "PR missing workspace/repo info")
		return nil
	end

	local endpoint =
		string.format("/repositories/%s/%s/pullrequests/%s?fields=description", workspace, repo, tostring(pr.id))
	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(json.safe_str(result.description) or "", nil)
	end, { action = "Fetch PR description", repo = pr.repo_full_name, id = pr.id })
end

---@param pr PullRequest
---@param fields table
---@param on_done fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
local function update_pullrequest(pr, fields, on_done)
	---@cast pr BitbucketPullRequest
	local url = tostring(pr.links.self or "")
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
	end, { action = "Update pull request", repo = pr.repo_full_name, id = pr.id })
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
	---@cast pr BitbucketPullRequest
	local merge_url = tostring(pr.links.merge or "")
	if merge_url == "" then
		on_done(nil, "No merge URL available")
		return nil
	end
	opts = opts or {}
	local payload = {}
	if opts.close_source_branch ~= nil then
		payload.close_source_branch = opts.close_source_branch == true
	end
	if opts.merge_strategy and opts.merge_strategy ~= "" then
		payload.merge_strategy = opts.merge_strategy
	end
	if opts.message and opts.message ~= "" then
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
	end, { action = "Merge pull request", repo = pr.repo_full_name, id = pr.id })
end

---@param pr PullRequest
---@param on_done fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.decline(pr, on_done)
	---@cast pr BitbucketPullRequest
	local url = tostring(pr.links.decline or "")
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
	end, { action = "Decline pull request", repo = pr.repo_full_name, id = pr.id })
end

---@param pr PullRequest
---@param on_done fun(participants: table[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_participants(pr, on_done)
	---@cast pr BitbucketPullRequest
	local self_url = tostring(pr.links.self or "")
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
	end, {
		action = "Fetch PR reviewers",
		repo = pr.repo_full_name,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewers(pr, opts, on_done)
	---@cast pr BitbucketPullRequest
	local self_url = tostring(pr.links.self or "")
	local key = "bitbucket:pr:reviewers:" .. self_url
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
	local starts = {
		defaults = function(done)
			return service.request("GET", endpoint, nil, nil, done, {
				action = "Fetch default reviewers",
				repo = slug,
			})
		end,
	}
	if opts.pr then
		starts.current = function(done)
			return M.fetch_reviewers(opts.pr, { force_refresh = true }, done)
		end
	end

	local requests = request_scope.new()
	requests.all(starts, function(results, errors)
		local err = errors.defaults or errors.current
		if err then
			on_done(nil, err)
			return
		end

		local current = results.current or {}
		local selected = {}
		for _, reviewer in ipairs(current) do
			local id = reviewer.role == "reviewer" and tostring(reviewer.provider_id or "") or ""
			if id ~= "" then
				selected[id] = true
			end
		end

		local reviewers = {}
		local found = {}
		local values = (results.defaults or {}).values or {}
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

		for _, reviewer in ipairs(current) do
			local uuid = reviewer.role == "reviewer" and tostring(reviewer.provider_id or "") or ""
			if uuid ~= "" and not found[uuid] then
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
	return requests
end

return M
