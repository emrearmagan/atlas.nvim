local M = {}

local cli = require("atlas.pulls.providers.github.api.cli")

---@param url string|nil
---@return integer|nil
function M.parse_run_id(url)
	local u = tostring(url or "")
	if u == "" then
		return nil
	end
	local id = u:match("/actions/runs/(%d+)")
	return id and tonumber(id) or nil
end

---@param slug string
---@param run_id integer
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.rerun_run(slug, run_id, on_done)
	local endpoint = string.format("repos/%s/actions/runs/%d/rerun", slug, run_id)
	return cli.gh({ "api", "-X", "POST", endpoint }, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end)
end

---Re-runs each unique Actions workflow run referenced by builds. Skips builds
---without a parsable run_id (external CI).
---@param slug string
---@param builds PullsBuild[]
---@param on_done fun(stats: { triggered: integer, skipped: integer, errors: string[] })
function M.rerun_all(slug, builds, on_done)
	local seen = {}
	local run_ids = {}
	local skipped = 0
	for _, b in ipairs(builds or {}) do
		local run_id = M.parse_run_id(b.url)
		if run_id and not seen[run_id] then
			seen[run_id] = true
			table.insert(run_ids, run_id)
		elseif not run_id then
			skipped = skipped + 1
		end
	end

	if #run_ids == 0 then
		on_done({ triggered = 0, skipped = skipped, errors = {} })
		return
	end

	local remaining = #run_ids
	local triggered = 0
	local errors = {}

	for _, run_id in ipairs(run_ids) do
		M.rerun_run(slug, run_id, function(ok, err)
			if ok then
				triggered = triggered + 1
			else
				table.insert(errors, tostring(err))
			end
			remaining = remaining - 1
			if remaining == 0 then
				on_done({ triggered = triggered, skipped = skipped, errors = errors })
			end
		end)
	end
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
---@param on_done fun(result: { mergeable: string, merge_state: string, review_decision: string, review_requests: string[], latest_reviews: { login: string, state: string }[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_merge_checks(pr, opts, on_done)
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

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(builds: PullsBuild[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_builds(pr, opts, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = string.format("github:builds:%s:%s", repo_slug, tostring(pr.id))
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
		"checks",
		tostring(pr.id),
		"--repo",
		repo_slug,
		"--json",
		"name,state,bucket,link,workflow",
	}, function(result, err)
		if err then
			if err:find("no checks") or err:find("no status checks") then
				cli.set_mem(cache_key, {})
				on_done({}, nil)
				return
			end
			on_done(nil, err)
			return
		end

		if type(result) ~= "table" then
			cli.set_mem(cache_key, {})
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

		cli.set_mem(cache_key, builds)
		on_done(builds, nil)
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
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(checks: PullsMergeCheck[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_merge_checks_summary(pr, opts, on_done)
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

	local h_mc = M.get_merge_checks(pr, opts, function(result, err)
		if err then
			first_err = first_err or err
		else
			mc_result = result
		end
		finish()
	end)

	local h_builds = M.get_builds(pr, opts, function(result, err)
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
