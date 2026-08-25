local M = {}

local pipeline_utils = require("atlas.pulls.pipelines")
local cli = require("atlas.providers.github.client")
local json = require("atlas.core.json")

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

local CHECK_CONCLUSION_STATES = {
	action_required = "FAILED",
	cancelled = "STOPPED",
	failure = "FAILED",
	neutral = "SUCCESSFUL",
	skipped = "STOPPED",
	stale = "STOPPED",
	startup_failure = "FAILED",
	success = "SUCCESSFUL",
	timed_out = "FAILED",
}

local STATUS_CONTEXT_STATES = {
	error = "FAILED",
	expected = "INPROGRESS",
	failure = "FAILED",
	pending = "INPROGRESS",
	success = "SUCCESSFUL",
}

local INPROGRESS_STATUSES = {
	in_progress = true,
	pending = true,
	queued = true,
	requested = true,
	waiting = true,
}

local CHECK_BUCKET_STATES = {
	pass = "SUCCESSFUL",
	fail = "FAILED",
	pending = "INPROGRESS",
	skipping = "STOPPED",
	cancel = "STOPPED",
}

---@param value any
---@return string
local function normalize_state(value)
	return tostring(value or ""):lower()
end

---@param conclusion any
---@return PullsPipelineState
local function conclusion_state(conclusion)
	return CHECK_CONCLUSION_STATES[normalize_state(conclusion)] or "UNKNOWN"
end

---@param check any
---@return PullsPipelineState
function M.status_check_state(check)
	if type(check) ~= "table" then
		return "UNKNOWN"
	end

	local context_state = STATUS_CONTEXT_STATES[normalize_state(check.state)]
	if context_state then
		return context_state
	end

	local conclusion = normalize_state(check.conclusion)
	if conclusion ~= "" then
		return conclusion_state(conclusion)
	end

	local status = normalize_state(check.status)
	if INPROGRESS_STATUSES[status] then
		return "INPROGRESS"
	end
	return "UNKNOWN"
end

---@param status any
---@param conclusion any
---@return PullsPipelineState
local function detail_state(status, conclusion)
	local normalized = normalize_state(status)
	if normalized == "completed" then
		return conclusion_state(conclusion)
	elseif INPROGRESS_STATUSES[normalized] then
		return "INPROGRESS"
	end
	return "UNKNOWN"
end

---@param check table
---@return PullsPipelineState
local function summary_state(check)
	return CHECK_BUCKET_STATES[normalize_state(check.bucket)] or M.status_check_state(check)
end

---@param value any
---@return string
local function summary_group_name(value)
	local workflow = vim.trim(tostring(value or ""))
	return workflow ~= "" and workflow or "External checks"
end

---@param url string|nil
---@return string|nil run_id
---@return string|nil job_id
---@return string|nil run_url
local function summary_ids(url)
	if url == nil or url == "" then
		return nil, nil, nil
	end
	local run_url, run_id = url:match("^(.-/actions/runs/(%d+))")
	return run_id, url:match("/job/(%d+)"), run_url
end

---@param pr PullRequest
---@param endpoint string
---@param action string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function post_pipeline_action(pr, endpoint, action, on_done)
	local repo_slug = tostring(pr.repo_full_name or "")
	if repo_slug == "" then
		on_done(false, "Missing repo")
		return nil
	end
	return cli.gh({ "api", "-X", "POST", string.format("repos/%s/%s", repo_slug, endpoint) }, function(_, err)
		on_done(err == nil, err)
	end, {
		action = action,
		repo = repo_slug,
		endpoint = endpoint,
	})
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param failed_only boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.rerun(pr, pipeline, failed_only, on_done)
	local run_id = tonumber(pipeline.id)
	if not run_id then
		on_done(false, "Missing workflow run ID")
		return nil
	end
	local action = failed_only and "rerun-failed-jobs" or "rerun"
	return post_pipeline_action(
		pr,
		string.format("actions/runs/%d/%s", run_id, action),
		failed_only and "Rerun failed pipeline jobs" or "Rerun pipeline",
		on_done
	)
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.cancel(pr, pipeline, on_done)
	local run_id = tonumber(pipeline.id)
	if not run_id then
		on_done(false, "Missing workflow run ID")
		return nil
	end
	return post_pipeline_action(pr, string.format("actions/runs/%d/cancel", run_id), "Cancel pipeline", on_done)
end

---@param pr PullRequest
---@param job PullsPipelineJob
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.rerun_job(pr, job, on_done)
	local job_id = tonumber(job.id)
	if not job_id then
		on_done(false, "Missing workflow job ID")
		return nil
	end
	return post_pipeline_action(pr, string.format("actions/jobs/%d/rerun", job_id), "Rerun pipeline job", on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
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
		"view",
		tostring(pr.id),
		"--repo",
		repo_slug,
		"--json",
		"statusCheckRollup",
	}, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		if type(result) ~= "table" then
			cli.set_mem(cache_key, {})
			on_done({}, nil)
			return
		end

		local pipelines = {}
		local pipelines_by_id = {}
		for index, check in ipairs(json.safe_table(result.statusCheckRollup)) do
			local url = json.safe_str(check.detailsUrl) or json.safe_str(check.targetUrl)
			local run_id, job_id, run_url = summary_ids(url)
			local name = summary_group_name(check.workflowName)
			local pipeline_id = run_id or ("external:" .. name)
			local pipeline = pipelines_by_id[pipeline_id]
			if pipeline == nil then
				pipeline = {
					id = pipeline_id,
					name = run_id and (name ~= "External checks" and name or "GitHub Actions") or name,
					state = "UNKNOWN",
					provider_state = "",
					url = run_url or url,
					job_count = 0,
					stages = {
						{
							name = nil,
							state = "UNKNOWN",
							jobs = {},
						},
					},
				}
				pipelines_by_id[pipeline_id] = pipeline
				table.insert(pipelines, pipeline)
			end

			local check_name = json.safe_str(check.name) or json.safe_str(check.context) or "Check"
			local synthetic_job_id = string.format("summary:%s:%s:%d", pipeline_id, check_name, index)
			table.insert(pipeline.stages[1].jobs, {
				id = (run_id and job_id) or synthetic_job_id,
				name = check_name,
				state = summary_state(check),
				provider_state = json.safe_str(check.state) or json.safe_str(check.bucket) or "",
				url = url,
				started_at = json.safe_str(check.startedAt),
				duration = duration(check.startedAt, check.completedAt),
			})
		end

		for _, pipeline in ipairs(pipelines) do
			local stage = pipeline.stages[1]
			local state = #stage.jobs > 0 and pipeline_utils.aggregate_state(stage.jobs) or "UNKNOWN"
			stage.state = state
			pipeline.state = state
			for _, job in ipairs(stage.jobs) do
				if job.state == state then
					pipeline.provider_state = job.provider_state
					break
				end
			end
			pipeline.job_count = #stage.jobs
		end

		cli.set_mem(cache_key, pipelines)
		on_done(pipelines, nil)
	end, {
		action = "Fetch PR pipelines",
		repo = repo_slug,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(pipeline: PullsPipeline|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_details(pr, pipeline, _opts, on_done)
	local repo_slug = tostring(pr.repo_full_name or "")
	local run_id = tonumber(pipeline.id)
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
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch pipeline details")
			return
		end

		local jobs = {}
		for _, raw_job in ipairs(result.jobs or {}) do
			local job_id = json.safe_str(raw_job.id) or ""
			local job = {
				id = job_id,
				name = tostring(raw_job.name or "Job"),
				state = detail_state(raw_job.status, raw_job.conclusion),
				provider_state = json.safe_str(raw_job.conclusion) or json.safe_str(raw_job.status) or "",
				url = json.safe_str(raw_job.html_url),
				started_at = raw_job.started_at,
				duration = duration(raw_job.started_at, raw_job.completed_at),
			}
			table.insert(jobs, job)
		end

		local detailed = vim.tbl_extend("force", {}, pipeline)
		detailed.job_count = #jobs
		detailed.stages = {
			{
				name = nil,
				state = #jobs > 0 and pipeline_utils.aggregate_state(jobs) or pipeline.state,
				jobs = jobs,
			},
		}
		on_done(detailed, nil)
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
function M.fetch_job_log(pr, _pipeline, job, on_done)
	local repo_slug = tostring(pr.repo_full_name or "")
	local job_id = tonumber(job.id)
	if repo_slug == "" or job_id == nil then
		vim.schedule(function()
			on_done(nil, repo_slug == "" and "Missing repo" or "Missing workflow job ID")
		end)
		return nil
	end

	if job.state == "INPROGRESS" then
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

return M
