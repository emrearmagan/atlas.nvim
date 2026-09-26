local cli = require("atlas.providers.github.client")
local json = require("atlas.core.json")

local M = {}

local MERGE_CHECKS_QUERY = [[
query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      mergeable
      reviewDecision
      reviewRequests(first: 100) {
        nodes { requestedReviewer { ... on User { login } ... on Bot { login } } }
      }
      reviews(first: 100, after: $endCursor) {
        nodes { author { login } state submittedAt }
        pageInfo { hasNextPage endCursor }
      }
      commits(last: 1) {
        nodes { commit { statusCheckRollup { state } } }
      }
    }
  }
}
]]

---@type table<string, "successful"|"failed"|"inprogress">
local PIPELINE_STATES = {
	ERROR = "failed",
	EXPECTED = "inprogress",
	FAILURE = "failed",
	PENDING = "inprogress",
	SUCCESS = "successful",
}

---@class GitHubMergeState
---@field mergeable string
---@field review_decision string
---@field review_requests string[]
---@field latest_reviews { login: string, state: string }[]
---@field pipeline_state "successful"|"failed"|"inprogress"|nil

---@return { login: string, state: "APPROVED"|"CHANGES_REQUESTED"|"COMMENTED"|"DISMISSED" }[], string[]
local function parse_reviews(review_nodes, request_nodes)
	local latest = {}
	local order = {}
	for _, review in ipairs(review_nodes) do
		local author = json.nilify(review.author)
		local login = author and tostring(author.login or "") or ""
		local state = tostring(review.state or ""):upper()
		if login ~= "" and state ~= "PENDING" then
			local at = tostring(review.submittedAt or "")
			local prev = latest[login]
			if prev == nil then
				table.insert(order, login)
				latest[login] = { state = state, at = at }
			elseif at >= prev.at then
				latest[login] = { state = state, at = at }
			end
		end
	end

	local reviews = {}
	for _, login in ipairs(order) do
		table.insert(reviews, { login = login, state = latest[login].state })
	end

	local pending = {}
	for _, req in ipairs(request_nodes) do
		local reviewer = json.safe_table(req.requestedReviewer)
		local login = tostring(reviewer.login or "")
		if login ~= "" and latest[login] == nil then
			table.insert(pending, login)
		end
	end

	return reviews, pending
end

---@param pr PullRequest
---@param on_done fun(result: GitHubMergeState|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_merge_state(pr, on_done)
	local repo_slug = pr.repo_full_name
	local owner, repo = repo_slug:match("^([^/]+)/([^/]+)$")
	if not owner then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	return cli.gh({
		"api",
		"graphql",
		"--paginate",
		"--slurp",
		"-f",
		"query=" .. MERGE_CHECKS_QUERY,
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. repo,
		"-F",
		"number=" .. tostring(pr.id),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch merge checks")
			return
		end

		local pull_request
		local review_nodes = {}
		for _, page in ipairs(result) do
			local repository = json.safe_table(json.safe_table(page.data).repository)
			local current = json.nilify(repository.pullRequest)
			if not current then
				on_done(nil, "Pull request not found")
				return
			end
			pull_request = pull_request or current
			vim.list_extend(review_nodes, current.reviews.nodes)
		end
		if not pull_request then
			on_done(nil, "Pull request not found")
			return
		end

		local latest_reviews, review_requests = parse_reviews(review_nodes, pull_request.reviewRequests.nodes)
		local last_commit = pull_request.commits.nodes[1]
		local rollup = last_commit and json.nilify(last_commit.commit.statusCheckRollup)
		local out = {
			mergeable = pull_request.mergeable,
			review_decision = json.safe_str(pull_request.reviewDecision) or "",
			review_requests = review_requests,
			latest_reviews = latest_reviews,
			pipeline_state = rollup and PIPELINE_STATES[rollup.state] or nil,
		}
		on_done(out, nil)
	end, {
		action = "Fetch PR merge state",
		repo = repo_slug,
		number = pr.id,
	})
end

---@param mc GitHubMergeState
---@return PullsMergeCheck
local function reviews_check(mc)
	local rd = tostring(mc.review_decision or "")
	local requests = mc.review_requests
	local reviews = mc.latest_reviews

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

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(checks: PullsMergeCheck[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
	local cache_key = string.format("github:merge-checks:%s:%s", pr.repo_full_name, tostring(pr.id))
	if not (opts or {}).force_refresh then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return fetch_merge_state(pr, function(mc_result, err)
		if not mc_result then
			on_done(nil, err or "Failed to load merge checks")
			return
		end
		local checks = {}
		if pr.state == "draft" then
			table.insert(checks, {
				key = "draft",
				state = "warning",
				label = "This pull request is still a work in progress",
				details = { "Draft pull requests cannot be merged." },
			})
		end
		table.insert(checks, reviews_check(mc_result))

		if mc_result.pipeline_state then
			table.insert(checks, {
				key = "pipelines",
				label = "Pipelines",
				state = mc_result.pipeline_state,
			})
		end

		local c = conflicts_check(mc_result.mergeable)
		if c then
			table.insert(checks, c)
		end

		cli.set_mem(cache_key, checks, cli.cache_ttl())
		on_done(checks, nil)
	end)
end

return M
