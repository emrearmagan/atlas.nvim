local M = {}

local pipeline_utils = require("atlas.pulls.pipelines")
local cli = require("atlas.providers.github.client")
local json = require("atlas.core.json")
local github_pipelines = require("atlas.pulls.providers.github.api.pipelines")

---@class GitHubMergeState
---@field mergeable string
---@field merge_state string
---@field review_decision string
---@field review_requests string[]
---@field latest_reviews { login: string, state: string }[]
---@field status_checks { state: PullsPipelineState }[]

---@return { login: string, state: "APPROVED"|"CHANGES_REQUESTED"|"COMMENTED"|"DISMISSED" }[], string[]
local function parse_reviews(result)
	local latest = {}
	local order = {}
	for _, review in ipairs(result.reviews or {}) do
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
	for _, req in ipairs(result.reviewRequests or {}) do
		local login = tostring(req.login or "")
		if login ~= "" and latest[login] == nil then
			table.insert(pending, login)
		end
	end

	return reviews, pending
end

---@param result table
---@return { state: PullsPipelineState }[]
local function parse_status_checks(result)
	local checks = {}
	for _, check in ipairs(result.statusCheckRollup or {}) do
		table.insert(checks, { state = github_pipelines.status_check_state(check) })
	end
	return checks
end

---@param pr PullRequest
---@param on_done fun(result: GitHubMergeState|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_merge_state(pr, on_done)
	local repo_slug = pr.repo_full_name
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
		"mergeable,mergeStateStatus,reviewDecision,reviewRequests,reviews,statusCheckRollup",
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch merge checks")
			return
		end

		local latest_reviews, review_requests = parse_reviews(result)
		local out = {
			mergeable = tostring(result.mergeable or ""),
			merge_state = tostring(result.mergeStateStatus or ""),
			review_decision = tostring(result.reviewDecision or ""),
			review_requests = review_requests,
			latest_reviews = latest_reviews,
			status_checks = parse_status_checks(result),
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
		if mc_result == nil then
			on_done(nil, err or "Failed to fetch merge checks")
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
		local b = pipeline_utils.to_merge_check(mc_result.status_checks, "Pipelines")
		if b then
			table.insert(checks, b)
		elseif mc_result.merge_state == "UNSTABLE" then
			table.insert(checks, {
				key = "pipelines",
				state = "warning",
				label = "Pipelines have not passed",
				details = { "A pipeline may be pending, failing, or require action." },
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
