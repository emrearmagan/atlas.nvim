local M = {}

local providers = require("atlas.pulls.providers")
local cli = require("atlas.providers.github.client")
local json = require("atlas.core.json")

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
	local run_id = tonumber(pipeline.provider_id) or M.parse_run_id(pipeline.url)
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
	local run_id = tonumber(pipeline.provider_id) or M.parse_run_id(pipeline.url)
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
	local job_id = parse_job_id(job.id) or parse_job_id(job.url)
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
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch pipeline details")
			return
		end

		local existing_jobs = {}
		for _, job in ipairs(pipeline.jobs or {}) do
			existing_jobs[tostring(job.id)] = job
		end

		local jobs = {}
		for _, raw_job in ipairs(result.jobs or {}) do
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
			for _, raw_step in ipairs(json.safe_table(raw_job.steps)) do
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
function M.fetch_job_log(pr, _pipeline, job, on_done)
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

return M
