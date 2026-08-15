local M = {}

local providers = require("atlas.pulls.providers")
local cli = require("atlas.providers.github.client").pulls
local pipelines = require("atlas.pulls.providers.github.api.pipelines")

---@return { login: string, state: "APPROVED"|"CHANGES_REQUESTED"|"COMMENTED"|"DISMISSED" }[], string[]
local function parse_reviews(result)
	local latest = {}
	local order = {}
	for _, review in ipairs(result.reviews or {}) do
		local login = type(review.author) == "table" and tostring(review.author.login or "") or ""
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
		local login = type(req) == "table" and tostring(req.login or "") or ""
		if login ~= "" and latest[login] == nil then
			table.insert(pending, login)
		end
	end

	return reviews, pending
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: { mergeable: string, merge_state: string, review_decision: string, review_requests: string[], latest_reviews: { login: string, state: string }[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_merge_state(pr, opts, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = string.format("github:merge_checks:%s:%s", repo_slug, tostring(pr.id))
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
		"mergeable,mergeStateStatus,reviewDecision,reviewRequests,reviews",
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
		}
		cli.set_mem(cache_key, out)
		on_done(out, nil)
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

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(checks: PullsMergeCheck[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
	local mc_result, pipelines_result
	local first_err
	local pending = 2

	local function finish()
		pending = pending - 1
		if pending > 0 then
			return
		end
		if mc_result == nil and pipelines_result == nil then
			on_done(nil, first_err or "Failed to fetch merge checks")
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
		if type(mc_result) == "table" then
			table.insert(checks, reviews_check(mc_result))
		end
		local b = providers.pipelines_check(pipelines_result, "Pipelines")
		if b then
			table.insert(checks, b)
		elseif type(mc_result) == "table" and mc_result.merge_state == "UNSTABLE" then
			table.insert(checks, {
				key = "pipelines",
				state = "warning",
				label = "Pipelines have not passed",
				details = { "A pipeline may be pending, failing, or require action." },
			})
		end
		if type(mc_result) == "table" then
			local c = conflicts_check(mc_result.mergeable)
			if c then
				table.insert(checks, c)
			end
		end

		on_done(checks, nil)
	end

	local h_mc = fetch_merge_state(pr, opts, function(result, err)
		if err then
			first_err = first_err or err
		else
			mc_result = result
		end
		finish()
	end)

	local h_pipelines = pipelines.fetch(pr, opts, function(result, err)
		if err then
			first_err = first_err or err
		else
			pipelines_result = result
		end
		finish()
	end)

	return {
		cancel = function()
			if h_mc and h_mc.cancel then
				h_mc.cancel()
			end
			if h_pipelines and h_pipelines.cancel then
				h_pipelines.cancel()
			end
		end,
	}
end

return M
