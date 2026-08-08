local M = {}

local providers = require("atlas.pulls.providers")
local cli = require("atlas.providers.github.client").pulls

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

---@param value string|integer|nil
---@return integer|nil
local function parse_job_id(value)
	local raw = tostring(value or "")
	local id = raw:match("^%d+$") or raw:match("/job/(%d+)")
	return id and tonumber(id) or nil
end

---@param started_at string|nil
---@param completed_at string|nil
---@return number|nil
local function duration(started_at, completed_at)
	local started = vim.fn.strptime("%Y-%m-%dT%H:%M:%SZ", tostring(started_at or ""))
	local completed = vim.fn.strptime("%Y-%m-%dT%H:%M:%SZ", tostring(completed_at or ""))
	if started <= 0 or completed < started then
		return nil
	end
	return completed - started
end

local CONCLUSION_STATE = {
	action_required = "FAILED",
	cancelled = "STOPPED",
	failure = "FAILED",
	neutral = "SUCCESSFUL",
	skipped = "STOPPED",
	stale = "STOPPED",
	success = "SUCCESSFUL",
	timed_out = "FAILED",
}

---@param status string|nil
---@param conclusion string|nil
---@return string
local function detail_state(status, conclusion)
	if tostring(status or ""):lower() ~= "completed" then
		return "INPROGRESS"
	end
	return CONCLUSION_STATE[tostring(conclusion or ""):lower()] or "UNKNOWN"
end

---@param pr PullRequest
---@param endpoint string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function post_pipeline_action(pr, endpoint, on_done)
	local repo_slug = tostring(pr.repo_full_name or "")
	if repo_slug == "" then
		on_done(false, "Missing repo")
		return nil
	end
	return cli.gh({ "api", "-X", "POST", string.format("repos/%s/%s", repo_slug, endpoint) }, function(_, err)
		on_done(err == nil, err)
	end)
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param failed_only boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.rerun_pipeline(pr, pipeline, failed_only, on_done)
	local run_id = tonumber(pipeline.provider_id) or M.parse_run_id(pipeline.url)
	if not run_id then
		on_done(false, "Missing workflow run ID")
		return nil
	end
	local action = failed_only and "rerun-failed-jobs" or "rerun"
	return post_pipeline_action(pr, string.format("actions/runs/%d/%s", run_id, action), on_done)
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.cancel_pipeline(pr, pipeline, on_done)
	local run_id = tonumber(pipeline.provider_id) or M.parse_run_id(pipeline.url)
	if not run_id then
		on_done(false, "Missing workflow run ID")
		return nil
	end
	return post_pipeline_action(pr, string.format("actions/runs/%d/cancel", run_id), on_done)
end

---@param pr PullRequest
---@param job PullsPipelineJob
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.rerun_pipeline_job(pr, job, on_done)
	local job_id = parse_job_id(job.id) or parse_job_id(job.url)
	if not job_id then
		on_done(false, "Missing workflow job ID")
		return nil
	end
	return post_pipeline_action(pr, string.format("actions/jobs/%d/rerun", job_id), on_done)
end

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
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_pipelines(pr, opts, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = string.format("github:pipelines:%s:%s", repo_slug, tostring(pr.id))
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
		"name,state,bucket,link,workflow,startedAt,completedAt",
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

		local pipelines = {}
		local pipelines_by_id = {}
		local commit_hash = tostring((pr.source or {}).commit_hash or "")
		for _, check in ipairs(result) do
			local url = check.link and tostring(check.link) or nil
			local run_id = M.parse_run_id(url)
			local state = BUCKET_MAP[tostring(check.bucket or "")] or "INPROGRESS"
			if run_id then
				local id = tostring(run_id)
				local pipeline = pipelines_by_id[id]
				if pipeline == nil then
					local workflow = tostring(check.workflow or "")
					pipeline = {
						name = workflow ~= "" and workflow or "GitHub Actions",
						state = "UNKNOWN",
						url = url and url:match("^(.-/actions/runs/%d+)") or nil,
						key = workflow ~= "" and workflow or id,
						provider_id = id,
						commit_hash = commit_hash,
						jobs = {},
					}
					pipelines_by_id[id] = pipeline
					table.insert(pipelines, pipeline)
				end
				table.insert(pipeline.jobs, {
					id = parse_job_id(url) or url or string.format("%s:%d", id, #pipeline.jobs + 1),
					name = tostring(check.name or "Job"),
					state = state,
					url = url,
					started_at = check.startedAt,
					completed_at = check.completedAt,
					duration = duration(check.startedAt, check.completedAt),
				})
			else
				table.insert(pipelines, {
					name = tostring(check.name or "External check"),
					state = state,
					url = url,
					key = check.workflow and tostring(check.workflow) or nil,
					commit_hash = commit_hash,
					jobs = {},
				})
			end
		end

		for _, pipeline in ipairs(pipelines) do
			if #pipeline.jobs > 0 then
				pipeline.state = providers.aggregate_pipeline_state(pipeline.jobs)
			end
		end

		cli.set_mem(cache_key, pipelines)
		on_done(pipelines, nil)
	end)
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(pipeline: PullsPipeline|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_pipeline_details(pr, pipeline, _opts, on_done)
	local repo_slug = tostring(pr.repo_full_name or "")
	local run_id = tonumber(pipeline.provider_id) or M.parse_run_id(pipeline.url)
	if run_id == nil then
		on_done(pipeline, nil)
		return nil
	end
	if repo_slug == "" then
		on_done(nil, "Missing repo")
		return nil
	end

	local endpoint = string.format("repos/%s/actions/runs/%d/jobs?per_page=100", repo_slug, run_id)
	return cli.gh({ "api", endpoint }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local existing_jobs = {}
		for _, job in ipairs(pipeline.jobs or {}) do
			existing_jobs[tostring(job.id)] = job
		end

		local jobs = {}
		for _, raw_job in ipairs(type(result) == "table" and result.jobs or {}) do
			local job_id = raw_job.id or ""
			local job = existing_jobs[tostring(job_id)] or {}
			job.id = job_id
			job.name = tostring(raw_job.name or "Job")
			job.state = detail_state(raw_job.status, raw_job.conclusion)
			job.provider_state = tostring(raw_job.conclusion or raw_job.status or "")
			job.url = type(raw_job.html_url) == "string" and raw_job.html_url or nil
			job.started_at = raw_job.started_at
			job.completed_at = raw_job.completed_at
			job.duration = duration(raw_job.started_at, raw_job.completed_at)
			job.steps = {}
			for _, raw_step in ipairs(type(raw_job.steps) == "table" and raw_job.steps or {}) do
				table.insert(job.steps, {
					id = string.format("%s:%s", tostring(job_id), tostring(raw_step.number or #job.steps + 1)),
					name = tostring(raw_step.name or "Step"),
					state = detail_state(raw_step.status, raw_step.conclusion),
					provider_state = tostring(raw_step.conclusion or raw_step.status or ""),
					started_at = raw_step.started_at,
					completed_at = raw_step.completed_at,
					duration = duration(raw_step.started_at, raw_step.completed_at),
				})
			end
			table.insert(jobs, job)
		end

		pipeline.jobs = jobs
		on_done(pipeline, nil)
	end, {
		action = "Fetch pipeline details",
		repo = repo_slug,
		run_id = run_id,
	})
end

---@param pr PullRequest
---@param _pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(log: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_pipeline_job_log(pr, _pipeline, job, on_done)
	local repo_slug = tostring(pr.repo_full_name or "")
	local job_id = parse_job_id(job.id) or parse_job_id(job.url)
	if repo_slug == "" or job_id == nil then
		vim.schedule(function()
			on_done(nil, repo_slug == "" and "Missing repo" or "Missing workflow job ID")
		end)
		return nil
	end

	if tostring(job.state or ""):upper() == "INPROGRESS" then
		on_done("Job is still in progress", nil)
		return nil
	end

	local endpoint = string.format("repos/%s/actions/jobs/%d/logs", repo_slug, job_id)
	return cli.gh_text({ "api", "--allow-escape-sequences", endpoint }, on_done, {
		action = "Fetch workflow job log",
		repo = repo_slug,
		job_id = job_id,
	})
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
function M.get_merge_checks_summary(pr, opts, on_done)
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

	local h_mc = M.get_merge_checks(pr, opts, function(result, err)
		if err then
			first_err = first_err or err
		else
			mc_result = result
		end
		finish()
	end)

	local h_pipelines = M.get_pipelines(pr, opts, function(result, err)
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
