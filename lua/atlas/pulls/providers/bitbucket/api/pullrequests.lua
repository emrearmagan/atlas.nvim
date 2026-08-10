local M = {}

local service = require("atlas.pulls.providers.bitbucket.api.service")
local mapper = require("atlas.pulls.providers.bitbucket.api.mapper")
local cache = require("atlas.core.cache")
local logger = require("atlas.core.logger")
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
---@param opts { cache_ttl: number, force: boolean, pagelen: number|nil, statuses: string[]|nil }
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
	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err then
			on_done({}, err)
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
	end, { action = "Fetching pull requests", workspace = workspace, repo = repo })
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
---@param draft boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.set_draft(pr, draft, on_done)
	return update_pullrequest(pr, { draft = draft }, on_done)
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
	for _, participant in ipairs(pr._raw.participants or {}) do
		local user = type(participant) == "table" and participant.user or nil
		if type(user) == "table" then
			local id = tostring(user.account_id or user.id or "")
			local username = tostring(user.nickname or user.username or "")
			local name = tostring(user.display_name or user.name or username)
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

	local body = vim.fn.empty(payload) == 1 and nil or vim.json.encode(payload)
	return service.request("POST", merge_url, nil, body, on_done)
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
	return service.request("POST", approve_url, nil, nil, on_done)
end

---@param pr PullRequest
---@param on_done fun(result: table|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.unapprove(pr, on_done)
	local approve_url = pr_link(pr, "approve")
	if approve_url == "" then
		on_done(nil, "No approve URL available")
		return nil
	end
	return service.request("DELETE", approve_url, nil, nil, on_done)
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
	return service.request("POST", request_changes_url, nil, nil, on_done)
end

---@param pr PullRequest
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.submit_review(pr, body, on_done)
	--TODO: How to resolve those pending comments tho ?
	if vim.trim(body) == "" then
		on_done(false, "Review comment cannot be empty")
		return nil
	end

	return require("atlas.pulls.providers.bitbucket.api.comments").add_comment(pr, body, nil, function(comment, err)
		if err or not comment then
			on_done(false, err or "Bitbucket did not return the review comment")
			return
		end
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param body string
---@param action fun(pr: PullRequest, on_done: fun(result: table|nil, err: string|nil)): { cancel: fun() }|nil
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
local function review_action(pr, body, action, on_done)
	local cancelled = false
	local current
	current = action(pr, function(_, err)
		if cancelled then
			return
		end
		if err or vim.trim(body) == "" then
			on_done(err == nil, err)
			return
		end
		current = M.submit_review(pr, body, on_done)
	end)
	return {
		cancel = function()
			cancelled = true
			if current then
				current.cancel()
			end
		end,
	}
end

---@param pr PullRequest
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.approve_review(pr, body, on_done)
	return review_action(pr, body, M.approve, on_done)
end

---@param pr PullRequest
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.request_changes_review(pr, body, on_done)
	return review_action(pr, body, M.request_changes, on_done)
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewers(pr, _opts, on_done)
	local raw = pr._raw
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

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(pr, _opts, on_done)
	local raw = pr._raw
	local activity_url = tostring((raw.links or {}).activity or "")
	if activity_url == "" then
		on_done({}, nil)
		return nil
	end

	return service.fetch_all_values(activity_url, function(result, err)
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
	local raw = pr._raw
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
	local raw = pr._raw
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
	local raw = pr._raw
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
		for _, participant in ipairs((opts.pr and opts.pr._raw.participants) or {}) do
			if tostring(participant.role or ""):upper() == "REVIEWER" then
				local user = type(participant.user) == "table" and participant.user or {}
				local uuid = tostring(user.uuid or "")
				if uuid ~= "" then
					selected[uuid] = true
					current[uuid] = user
				end
			end
		end

		local reviewers = {}
		local found = {}
		local values = type(result) == "table" and type(result.values) == "table" and result.values or {}
		for _, entry in ipairs(values) do
			local user = type(entry) == "table" and (type(entry.user) == "table" and entry.user or entry) or {}
			local uuid = type(user) == "table" and tostring(user.uuid or "") or ""
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

		for uuid, user in pairs(current) do
			if not found[uuid] then
				local nickname = tostring(user.nickname or "")
				local name = tostring(user.display_name or "")
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
