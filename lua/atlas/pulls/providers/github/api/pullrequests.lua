local M = {}

local cli = require("atlas.pulls.providers.github.api.cli")
local normalizer = require("atlas.pulls.providers.github.api.normalizer")
local logger = require("atlas.core.logger")

local GET_PR_GQL = [[
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      number title state isDraft
      createdAt updatedAt url body
      additions deletions changedFiles
      reviewDecision
      labels(first: 10) { nodes { name color } }
      latestOpinionatedReviews(last: 10) { nodes { state } }
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
        number title state isDraft
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
		local cached, ok = cli.get_cache(cache_key)
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
		cli.set_cache(cache_key, pr)
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
		local cached, ok = cli.get_cache(cache_key)
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
		cli.set_cache(cache_key, body)
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
		local cached, ok = cli.get_cache(cache_key)
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

		cli.set_cache(cache_key, reviewers)
		on_done(reviewers, nil)
	end)
end

---@param pr PullRequest
---@param on_done fun(result: { mergeable: string, merge_state: string, review_decision: string, review_requests: string[], latest_reviews: { login: string, state: string }[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_merge_checks(pr, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	return cli.gh({
		"pr",
		"view",
		tostring(pr.id),
		"--repo",
		repo_slug,
		"--json",
		"mergeable,mergeStateStatus,reviewDecision,reviewRequests,reviews",
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch merge checks")
			return
		end

		local latest_reviews, review_requests = parse_reviews(result)

		on_done({
			mergeable = tostring(result.mergeable or ""),
			merge_state = tostring(result.mergeStateStatus or ""),
			review_decision = tostring(result.reviewDecision or ""),
			review_requests = review_requests,
			latest_reviews = latest_reviews,
		}, nil)
	end)
end

---@param pr PullRequest
---@param on_done fun(builds: PullsBuild[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_builds(pr, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	return cli.gh({
		"pr",
		"checks",
		tostring(pr.id),
		"--repo",
		repo_slug,
		"--json",
		"name,state,bucket,link,workflow",
	}, function(result, err)
		if err then
			if err:find("no checks") or err:find("no status checks") then
				on_done({}, nil)
				return
			end
			on_done(nil, err)
			return
		end

		if type(result) ~= "table" then
			on_done({}, nil)
			return
		end

		local BUCKET_MAP = {
			pass = "SUCCESSFUL",
			fail = "FAILED",
			pending = "INPROGRESS",
			skipping = "STOPPED",
			cancel = "STOPPED",
		}

		local builds = {}
		for _, check in ipairs(result) do
			table.insert(builds, {
				name = tostring(check.name or ""),
				state = BUCKET_MAP[tostring(check.bucket or "")] or "INPROGRESS",
				url = check.link and tostring(check.link) or nil,
				key = check.workflow and tostring(check.workflow) or nil,
			})
		end

		on_done(builds, nil)
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
		local cached, ok = cli.get_cache(cache_key)
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

		cli.set_cache(cache_key, entries)
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

---@param mc table  result from get_merge_checks
---@return PullsMergeCheck
local function reviews_check(mc)
	local rd = tostring(mc.review_decision or "")
	local requests = mc.review_requests or {}
	local reviews = mc.latest_reviews or {}

	local approved, changes_requested = 0, 0
	for _, r in ipairs(reviews) do
		if r.state == "APPROVED" then
			approved = approved + 1
		elseif r.state == "CHANGES_REQUESTED" then
			changes_requested = changes_requested + 1
		end
	end

	if approved == 0 and changes_requested == 0 and #requests == 0 then
		return { key = "reviews", state = "muted", label = "Reviews", details = { "No review required" } }
	end

	local details = {}
	if approved > 0 then
		table.insert(details, string.format("%d %s", approved, approved == 1 and "approval" or "approvals"))
	end
	if changes_requested > 0 then
		table.insert(
			details,
			string.format(
				"%d %s requested changes",
				changes_requested,
				changes_requested == 1 and "reviewer" or "reviewers"
			)
		)
	end
	if #requests > 0 then
		table.insert(details, string.format("%d pending %s", #requests, #requests == 1 and "review" or "reviews"))
	end

	local state
	if rd == "CHANGES_REQUESTED" or changes_requested > 0 then
		state = "failed"
	elseif #requests > 0 or rd == "REVIEW_REQUIRED" then
		state = "warning"
	elseif rd == "APPROVED" or approved > 0 then
		state = "successful"
	else
		state = "muted"
	end

	return { key = "reviews", state = state, label = "Reviews", details = details }
end

---@param mergeable string
---@return PullsMergeCheck|nil
local function conflicts_check(mergeable)
	local m = tostring(mergeable or "")
	if m == "MERGEABLE" then
		return {
			key = "conflicts",
			state = "successful",
			label = "No conflicts with base branch",
			details = { "Changes can be cleanly merged." },
		}
	elseif m == "CONFLICTING" then
		return {
			key = "conflicts",
			state = "failed",
			label = "This branch has conflicts that must be resolved",
			details = { "Conflicting files must be resolved before merging." },
		}
	end
	return nil
end

---@param builds PullsBuild[]
---@return PullsMergeCheck|nil
local function builds_check(builds)
	if type(builds) ~= "table" or #builds == 0 then
		return nil
	end

	local total, pass, fail, ip, stop = #builds, 0, 0, 0, 0
	for _, b in ipairs(builds) do
		local s = tostring(b.state or ""):upper()
		if s == "SUCCESSFUL" then
			pass = pass + 1
		elseif s == "FAILED" then
			fail = fail + 1
		elseif s == "INPROGRESS" then
			ip = ip + 1
		elseif s == "STOPPED" then
			stop = stop + 1
		end
	end

	local state, detail
	if fail > 0 then
		state = "failed"
		detail = string.format("%d of %d failed", fail, total)
	elseif ip > 0 then
		state = "inprogress"
		detail = string.format("%d of %d in progress", ip, total)
	elseif pass > 0 then
		state = "successful"
		if stop > 0 then
			detail = string.format("%d/%d successful (%d skipped)", pass, total, stop)
		else
			detail = string.format("%d/%d successful", pass, total)
		end
	elseif stop == total then
		state = "muted"
		detail = string.format("All %d checks skipped", total)
	else
		state = "muted"
		detail = string.format("%d of %d unknown", total - pass - fail - ip - stop, total)
	end

	return { key = "builds", state = state, label = "Builds", details = { detail } }
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(checks: PullsMergeCheck[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_merge_checks_summary(pr, _opts, on_done)
	local mc_result, builds_result
	local first_err
	local pending = 2

	local function finish()
		pending = pending - 1
		if pending > 0 then
			return
		end
		if mc_result == nil and builds_result == nil then
			on_done(nil, first_err or "Failed to fetch merge checks")
			return
		end

		local checks = {}
		if type(mc_result) == "table" then
			table.insert(checks, reviews_check(mc_result))
		end
		local b = builds_check(builds_result)
		if b then
			table.insert(checks, b)
		end
		if type(mc_result) == "table" then
			local c = conflicts_check(mc_result.mergeable)
			if c then
				table.insert(checks, c)
			end
		end

		on_done(checks, nil)
	end

	local h_mc = M.get_merge_checks(pr, function(result, err)
		if err then
			first_err = first_err or err
		else
			mc_result = result
		end
		finish()
	end)

	local h_builds = M.get_builds(pr, function(result, err)
		if err then
			first_err = first_err or err
		else
			builds_result = result
		end
		finish()
	end)

	return {
		cancel = function()
			if h_mc and h_mc.cancel then
				h_mc.cancel()
			end
			if h_builds and h_builds.cancel then
				h_builds.cancel()
			end
		end,
	}
end

return M
