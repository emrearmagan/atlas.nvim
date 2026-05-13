local M = {}

local cli = require("atlas.pulls.providers.github.api.cli")
local normalizer = require("atlas.pulls.providers.github.api.normalizer")
local logger = require("atlas.core.logger")

local GET_PR_GQL = [[
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      id number title state isDraft viewerSubscription
      createdAt updatedAt url body
      additions deletions changedFiles
      reviewDecision
      labels(first: 10) { nodes { name color } }
      milestone { number title state }
      latestOpinionatedReviews(last: 10) { nodes { state author { login } } }
      assignees(first: 10) { nodes { login } }
      author { login ... on User { name } }
      headRefName baseRefName headRefOid baseRefOid
      comments { totalCount }
      commits(last: 1) {
        nodes { commit { statusCheckRollup { state } } }
      }
    }
  }
}
]]

local SEARCH_GQL = [[
query($search: String!, $limit: Int!) {
  search(query: $search, type: ISSUE, first: $limit) {
    nodes {
      ... on PullRequest {
        id number title state isDraft
        createdAt updatedAt url
        additions deletions
        latestOpinionatedReviews(last: 10) { nodes { state } }
        author { login ... on User { name } }
        headRefName baseRefName
        comments { totalCount }
        repository { name nameWithOwner }
        commits(last: 1) {
          nodes { commit { statusCheckRollup { state } } }
        }
      }
    }
  }
}
]]

---@param search string
---@param on_done fun(groups: PullsGroup[], err: string[]|nil)
---@param opts { force_load?: boolean, limit?: number }|nil
---@return { cancel: fun() }|nil
function M.search_prs(search, on_done, opts)
	opts = opts or {}
	local limit = math.max(1, tonumber(opts.limit) or 50)
	local cache_key = string.format("github:search:%s:limit:%d", search, limit)

	if not opts.force_load then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	logger.loginfo("GitHub GraphQL search PRs", { search = search, limit = limit })

	return cli.gh({
		"api",
		"graphql",
		"-f",
		"query=" .. vim.trim(SEARCH_GQL),
		"-f",
		"search=" .. search,
		"-F",
		"limit=" .. tostring(limit),
	}, function(result, err)
		if err then
			on_done({}, { err })
			return
		end

		local nodes = type(result) == "table"
				and type(result.data) == "table"
				and type(result.data.search) == "table"
				and result.data.search.nodes
			or nil

		if type(nodes) ~= "table" then
			on_done({}, nil)
			return
		end

		local prs = normalizer.normalize_graphql_search_results(nodes)
		local groups = normalizer.group_by_repo(prs)

		cli.set_cache(cache_key, groups)
		logger.loginfo("GitHub GraphQL search complete", { count = #prs, groups = #groups })
		on_done(groups, nil)
	end)
end

---@param owner string
---@param repo string
---@param number number|string
---@param on_done fun(pr: PullRequest|nil, err: string|nil)
---@param opts { force_load?: boolean }|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.get_pr(owner, repo, number, on_done, opts)
	opts = opts or {}
	local repo_slug = string.format("%s/%s", owner, repo)
	local cache_key = string.format("github:pr:%s:%s", repo_slug, tostring(number))

	if not opts.force_load then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	logger.loginfo("GitHub fetch PR", { repo = repo_slug, number = number })

	return cli.gh({
		"api",
		"graphql",
		"-f",
		"query=" .. vim.trim(GET_PR_GQL),
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. repo,
		"-F",
		"number=" .. tostring(number),
	}, function(result, err)
		if err or not result or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch PR")
			return
		end

		local pr_raw = type(result.data) == "table"
			and type(result.data.repository) == "table"
			and result.data.repository.pullRequest
		if type(pr_raw) ~= "table" then
			on_done(nil, "PR not found")
			return
		end

		pr_raw.repository = { name = repo, nameWithOwner = repo_slug }
		local pr = normalizer.normalize_pr(pr_raw)
		cli.set_mem(cache_key, pr)
		on_done(pr, nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(description: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_description(pr, opts, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = string.format("github:desc:%s:%s", repo_slug, tostring(pr.id))
	opts = opts or {}

	if not opts.force_refresh then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"pr",
		"view",
		tostring(pr.id),
		"--repo",
		repo_slug,
		"--json",
		"body",
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch description")
			return
		end
		local body = tostring(result.body or "")
		cli.set_mem(cache_key, body)
		on_done(body, nil)
	end)
end

---@return { login: string, state: "APPROVED"|"CHANGES_REQUESTED"|"COMMENTED" }[], string[]
local function parse_reviews(result)
	local states = {}
	local order = {}
	for _, review in ipairs(result.reviews or {}) do
		local login = type(review.author) == "table" and tostring(review.author.login or "") or ""
		local state = tostring(review.state or ""):upper()
		if login ~= "" then
			if state == "APPROVED" or state == "CHANGES_REQUESTED" then
				if states[login] == nil then
					table.insert(order, login)
				end
				states[login] = state
			elseif state == "COMMENTED" and states[login] == nil then
				table.insert(order, login)
				states[login] = "COMMENTED"
			end
		end
	end

	local reviews = {}
	for _, login in ipairs(order) do
		table.insert(reviews, { login = login, state = states[login] })
	end

	local pending = {}
	for _, req in ipairs(result.reviewRequests or {}) do
		local login = type(req) == "table" and tostring(req.login or "") or ""
		if login ~= "" and states[login] == nil then
			table.insert(pending, login)
		end
	end

	return reviews, pending
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_reviewers(pr, opts, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = string.format("github:reviewers:%s:%s", repo_slug, tostring(pr.id))
	opts = opts or {}

	if not opts.force_refresh then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"pr",
		"view",
		tostring(pr.id),
		"--repo",
		repo_slug,
		"--json",
		"reviews,reviewRequests",
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch reviewers")
			return
		end

		local reviews, pending = parse_reviews(result)

		local reviewers = {}
		for _, r in ipairs(reviews) do
			local decision = "pending"
			if r.state == "APPROVED" then
				decision = "approved"
			elseif r.state == "CHANGES_REQUESTED" then
				decision = "changes_requested"
			end
			table.insert(reviewers, { name = r.login, nickname = r.login, decision = decision })
		end
		for _, login in ipairs(pending) do
			table.insert(reviewers, { name = login, nickname = login, decision = "pending" })
		end

		cli.set_mem(cache_key, reviewers)
		on_done(reviewers, nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_diffstat(pr, opts, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = string.format("github:diffstat:%s:%s", repo_slug, tostring(pr.id))
	opts = opts or {}

	if not opts.force_refresh then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"pr",
		"view",
		tostring(pr.id),
		"--repo",
		repo_slug,
		"--json",
		"files",
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch files")
			return
		end

		local entries = {}
		for _, file in ipairs(result.files or {}) do
			local additions = tonumber(file.additions) or 0
			local deletions = tonumber(file.deletions) or 0
			local status = "modified"
			if additions > 0 and deletions == 0 then
				status = "added"
			elseif additions == 0 and deletions > 0 then
				status = "removed"
			end

			table.insert(entries, {
				status = status,
				path = tostring(file.path or ""),
				old_path = nil,
				lines_added = additions,
				lines_removed = deletions,
			})
		end

		cli.set_mem(cache_key, entries)
		on_done(entries, nil)
	end)
end

---@param opts PullsCreatePROpts
---@param on_done fun(result: PullsCreatePRResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_pr(opts, on_done)
	local slug = tostring(opts.repo_slug or "")
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	local args = {
		"pr",
		"create",
		"--repo",
		slug,
		"--head",
		opts.head,
		"--base",
		opts.base,
		"--title",
		opts.title,
		"--body",
		opts.body or "",
	}
	if opts.draft then
		table.insert(args, "--draft")
	end

	for _, reviewer in ipairs(opts.reviewers or {}) do
		table.insert(args, "--reviewer")
		table.insert(args, reviewer.provider_id)
	end

	logger.loginfo("github.create_pr", { slug = slug, head = opts.head, base = opts.base, draft = opts.draft == true })

	return cli.gh(args, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		-- gh prints the new PR URL on stdout. result is either a parsed table
		-- (unlikely here) or a string (the URL). Trim and surface it.
		local url = nil
		local id = nil
		if type(result) == "string" then
			url = vim.trim(result)
			-- last segment of /pull/<id>
			id = url:match("/pull/(%d+)")
			if id then
				id = tonumber(id) or id
			end
		end

		on_done({ id = id, url = url, message = "PR created" }, nil)
	end)
end

---@param slug string
---@param on_done fun(labels: table[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_labels(slug, on_done)
	if type(slug) ~= "string" or slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	return cli.gh({
		"api",
		"--paginate",
		string.format("repos/%s/labels?per_page=100", slug),
	}, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local list = {}
		if type(result) == "table" then
			for _, raw in ipairs(result) do
				if type(raw) == "table" and type(raw.name) == "string" then
					table.insert(list, {
						name = raw.name,
						color = type(raw.color) == "string" and raw.color or nil,
						description = type(raw.description) == "string" and raw.description or nil,
					})
				end
			end
		end
		on_done(list, nil)
	end)
end

---@param slug string
---@param number integer|string
---@param diff { add?: string[], remove?: string[] }
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_labels(slug, number, diff, on_done)
	local adds = type(diff) == "table" and diff.add or {}
	local removes = type(diff) == "table" and diff.remove or {}
	if #adds == 0 and #removes == 0 then
		on_done(true, nil)
		return nil
	end

	local args = { "pr", "edit", tostring(number), "--repo", slug }
	for _, v in ipairs(adds) do
		table.insert(args, "--add-label")
		table.insert(args, tostring(v))
	end
	for _, v in ipairs(removes) do
		table.insert(args, "--remove-label")
		table.insert(args, tostring(v))
	end

	return cli.gh(args, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end)
end

return M
