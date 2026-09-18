local M = {}

local pipeline_utils = require("atlas.pulls.pipelines")
local cli = require("atlas.providers.github.client")
local json = require("atlas.core.json")

local COMMIT_STATUS_QUERY = [[
query($owner: String!, $repo: String!, $sha: String!) {
  repository(owner: $owner, name: $repo) {
    object(expression: $sha) {
      ... on Commit {
        statusCheckRollup {
          state
          contexts(first: 1) {
            nodes {
              ... on CheckRun { url: detailsUrl }
              ... on StatusContext { url: targetUrl }
            }
          }
        }
      }
    }
  }
}
]]

local COMMIT_STATUS_STATES = {
	ERROR = "failed",
	EXPECTED = "inprogress",
	FAILURE = "failed",
	PENDING = "inprogress",
	SUCCESS = "successful",
}

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
		"checks",
		tostring(pr.id),
		"--repo",
		repo_slug,
		"--json",
		"name,workflow,state,bucket,link,startedAt,completedAt",
	}, function(result, err)
		if err and not err:match("^no checks reported") then
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
		for index, check in ipairs(result) do
			local url = json.safe_str(check.link)
			local run_id, job_id, run_url = summary_ids(url)
			local name = summary_group_name(check.workflow)
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

			local check_name = json.safe_str(check.name) or "Check"
			local synthetic_job_id = string.format("summary:%s:%s:%d", pipeline_id, check_name, index)
			table.insert(pipeline.stages[1].jobs, {
				id = (run_id and job_id) or synthetic_job_id,
				name = check_name,
				state = CHECK_BUCKET_STATES[check.bucket] or "UNKNOWN",
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
	return cli.gh({ "api", endpoint, "--paginate", "--slurp" }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch pipeline details")
			return
		end

		local jobs = {}
		local total_count
		local pages = result.jobs and { result } or result
		for _, page in ipairs(pages) do
			total_count = total_count or tonumber(page.total_count)
			for _, raw_job in ipairs(page.jobs or {}) do
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
		end

		local detailed = vim.tbl_extend("force", {}, pipeline)
		detailed.job_count = total_count or #jobs
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

---@param commit PullsCommit
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(status: string|nil, url: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commit_status(commit, opts, on_done)
	local owner, repo = (commit.repo_full_name or ""):match("^([^/]+)/([^/]+)$")
	if not owner then
		on_done(nil, nil, "Missing repo")
		return nil
	end

	local cache_key = string.format("github:commit:statuses:%s:%s", commit.repo_full_name, commit.hash)
	if not (opts or {}).force_refresh then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached.status, cached.url, nil)
			return nil
		end
	end

	return cli.gh({
		"api",
		"graphql",
		"-f",
		"query=" .. COMMIT_STATUS_QUERY,
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. repo,
		"-f",
		"sha=" .. commit.hash,
	}, function(result, err)
		if err then
			on_done(nil, nil, err)
			return
		end

		local repository = json.safe_table(json.safe_table(result.data).repository)
		local raw_commit = json.safe_table(repository.object)
		local rollup = json.safe_table(raw_commit.statusCheckRollup)
		local contexts = json.safe_table(rollup.contexts)
		local context = json.safe_table(json.safe_table(contexts.nodes)[1])
		local status = COMMIT_STATUS_STATES[rollup.state] or "unknown"
		local url = json.safe_str(context.url)
		cli.set_mem(cache_key, { status = status, url = url })
		on_done(status, url, nil)
	end, {
		action = "Fetch commit status",
		repo = commit.repo_full_name,
		commit_hash = commit.hash,
	})
end

return M
