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

--TODO: This query already fetched most of the stuff. I could probably extend it slightly and then in the overview page i could instantly show more details without having to fetch the PR again. Like reviewers, build status etc.
local SEARCH_GQL = [[
query($search: String!, $limit: Int!) {
  search(query: $search, type: ISSUE, first: $limit) {
    nodes {
      ... on PullRequest {
        number title state isDraft
        createdAt updatedAt url
        additions deletions changedFiles
        labels(first: 10) { nodes { name color } }
        latestOpinionatedReviews(last: 10) { nodes { state } }
        author { login ... on User { name } }
        headRefName baseRefName headRefOid baseRefOid
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
---@param on_done fun(result: { mergeable: string, merge_state: string, review_decision: string }|nil, err: string|nil)
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
		"mergeable,mergeStateStatus,reviewDecision",
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch merge checks")
			return
		end
		on_done({
			mergeable = tostring(result.mergeable or ""),
			merge_state = tostring(result.mergeStateStatus or ""),
			review_decision = tostring(result.reviewDecision or ""),
		}, nil)
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

return M
