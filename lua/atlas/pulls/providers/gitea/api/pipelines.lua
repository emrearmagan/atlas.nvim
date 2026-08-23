local service = require("atlas.providers.gitea.client").pulls
local pagination = require("atlas.providers.gitea.pagination").pulls
local providers = require("atlas.pulls.providers")
local request_scope = require("atlas.core.requests")

local M = {}

---@param slug string|nil
---@param value string|nil
---@return string|nil run_id, string|nil run_url, string|nil job_id
function M.actions_run(slug, value)
	local owner, repo = tostring(slug or ""):match("^([^/]+)/([^/]+)$")
	local url = service.absolute_url(value)
	if not owner or not url then
		return nil, nil
	end
	url = assert(url:match("^[^?#]+"))
	local prefix = string.format("%s/%s/%s/actions/runs/", service.base_url(), owner, repo)
	if url:sub(1, #prefix) ~= prefix then
		return nil, nil
	end
	local run_id, tail = url:sub(#prefix + 1):match("^(%d+)(.*)$")
	local job_id = tail:match("^/jobs/(%d+)/?$")
	if not run_id or (tail ~= "" and tail ~= "/" and not job_id) then
		return nil, nil
	end
	return run_id, prefix .. run_id, job_id
end

---@param value string|nil
---@param conclusion string|nil
---@return "SUCCESSFUL"|"FAILED"|"INPROGRESS"|"STOPPED"|"UNKNOWN"
function M.state(value, conclusion)
	local state = (conclusion or ""):lower()
	if state == "" then
		state = (value or ""):lower()
	end
	if state == "success" then
		return "SUCCESSFUL"
	elseif state == "failure" or state == "error" then
		return "FAILED"
	elseif
		state == "pending"
		or state == "queued"
		or state == "in_progress"
		or state == "waiting"
		or state == "running"
		or state == "blocked"
		or state == "cancelling"
	then
		return "INPROGRESS"
	elseif state == "warning" or state == "skipped" or state == "cancelled" or state == "canceled" then
		return "STOPPED"
	end
	return "UNKNOWN"
end

---@param slug string|nil
---@param sha string|nil
---@return string|nil
local function status_endpoint(slug, sha)
	local owner, repo = tostring(slug or ""):match("^([^/]+)/([^/]+)$")
	sha = tostring(sha or "")
	if not owner or sha == "" then
		return nil
	end
	return string.format(
		"/repos/%s/%s/statuses/%s",
		service.url_encode(owner),
		service.url_encode(repo),
		service.url_encode(sha)
	)
end

---@param endpoint string
---@param on_done fun(result: table[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_statuses(endpoint, on_done)
	local seen = {}
	return pagination.fetch_all(endpoint, { sort = "leastindex" }, {
		accept = function(raw)
			local context = raw.context or ""
			local key = "context:" .. context
			if seen[key] then
				return false
			end
			seen[key] = true
			return true
		end,
	}, on_done)
end

---@param raw table
---@param sha string
---@return PullsPipeline
local function external_pipeline(raw, sha)
	local context = raw.context or ""
	local id = tostring(raw.id)
	local name = context ~= "" and context or (raw.description or "")
	return {
		name = name ~= "" and name or "Commit status",
		state = M.state(raw.status),
		provider_state = raw.status,
		provider_context = context,
		url = service.absolute_url(raw.target_url),
		key = context ~= "" and context or (id ~= "" and id or nil),
		provider_id = id ~= "" and id or nil,
		commit_hash = sha,
		jobs = {},
	}
end

---@param result table[]
---@param sha string
---@param slug string|nil
---@return PullsPipeline[]
function M.map(result, sha, slug)
	local pipelines = {}
	local actions_runs = {}

	for _, raw in ipairs(result) do
		local target_url = service.absolute_url(raw.target_url)
		local run_id, run_url, job_id = M.actions_run(slug, target_url)
		if not run_id then
			table.insert(pipelines, external_pipeline(raw, sha))
		else
			local context = raw.context or ""
			local workflow, job_name = context:match("^(.-)%s+/%s+(.+)$")
			local pipeline = actions_runs[run_id]
			if not pipeline then
				pipeline = {
					name = workflow or ("Actions run #" .. run_id),
					state = "UNKNOWN",
					url = run_url,
					key = workflow or run_id,
					provider_id = run_id,
					commit_hash = sha,
					jobs = {},
				}
				actions_runs[run_id] = pipeline
				table.insert(pipelines, pipeline)
			end

			local provider_state = raw.status
			table.insert(pipeline.jobs, {
				id = tonumber(job_id) or raw.id,
				name = job_name or (context ~= "" and context or "Job"),
				state = M.state(provider_state),
				provider_state = provider_state,
				provider_context = context,
				url = target_url,
				steps = {},
			})
		end
	end

	for _, pipeline in ipairs(pipelines) do
		if #pipeline.jobs > 0 then
			pipeline.state = providers.aggregate_pipeline_state(pipeline.jobs)
			pipeline.provider_state = pipeline.state:lower()
		end
	end
	return pipelines
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, _opts, on_done)
	local sha = pr.source.commit_hash
	local endpoint = status_endpoint(pr.repo_full_name, sha)
	if not endpoint then
		on_done(nil, "Invalid Gitea repository or source commit")
		return nil
	end

	return fetch_statuses(endpoint, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(M.map(result, sha, pr.repo_full_name), nil)
	end)
end

---@param commit PullsCommit
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(status: string|nil, url: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commit_status(commit, _opts, on_done)
	local endpoint = tostring(commit.statuses_url or "")
	if endpoint == "" then
		on_done("unknown", nil, nil)
		return nil
	end

	return fetch_statuses(endpoint, function(result, err)
		if err then
			on_done(nil, nil, err)
			return
		end
		local pipelines = M.map(result, commit.hash, nil)
		local url
		for _, pipeline in ipairs(pipelines) do
			if not url then
				local first_job = pipeline.jobs[1]
				url = pipeline.url or (first_job and first_job.url)
			end
		end
		on_done(providers.aggregate_pipeline_state(pipelines):lower(), url, nil)
	end)
end

---@param pr PullRequest
---@return string|nil
local function repo_endpoint(pr)
	local owner, repo = pr.repo_full_name:match("^([^/]+)/([^/]+)$")
	if not owner then
		return nil
	end
	return string.format("/repos/%s/%s", service.url_encode(owner), service.url_encode(repo))
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@return integer|nil
function M.parse_run_id(pr, pipeline)
	local run_id = M.actions_run(pr.repo_full_name, pipeline.url)
	return tonumber(run_id)
end

---@param value string|nil
---@return string|nil
local function timestamp(value)
	local result = value
	if
		result == nil
		or result == ""
		or result:match("^0001%-01%-01T00:00:00")
		or result:match("^1970%-01%-01T00:00:00")
	then
		return nil
	end
	return result
end

---@param started_at string|nil
---@param completed_at string|nil
---@return number|nil
local function duration(started_at, completed_at)
	if started_at == nil or completed_at == nil then
		return nil
	end
	local started = vim.fn.strptime("%Y-%m-%dT%H:%M:%SZ", started_at)
	local completed = vim.fn.strptime("%Y-%m-%dT%H:%M:%SZ", completed_at)
	if started <= 0 or completed < started then
		return nil
	end
	return completed - started
end

---@param raw table
---@return string
local function provider_state(raw)
	local conclusion = raw.conclusion or ""
	if conclusion ~= "" then
		return conclusion
	end
	return raw.status or ""
end

---@param raw table
---@param job_id string|integer
---@return PullsPipelineStep
local function map_step(raw, job_id)
	local started_at = timestamp(raw.started_at)
	local completed_at = timestamp(raw.completed_at)
	return {
		id = string.format("%s:%s", tostring(job_id), tostring(raw.number)),
		name = raw.name,
		state = M.state(raw.status, raw.conclusion),
		provider_state = provider_state(raw),
		started_at = started_at,
		completed_at = completed_at,
		duration = duration(started_at, completed_at),
	}
end

---@param raw { jobs: table[] }
---@return PullsPipelineJob[]
local function map_jobs(raw)
	local jobs = {}
	for _, value in ipairs(raw.jobs) do
		local started_at = timestamp(value.started_at)
		local completed_at = timestamp(value.completed_at)
		local steps = {}
		for _, step in ipairs(value.steps) do
			table.insert(steps, map_step(step, value.id))
		end
		table.insert(jobs, {
			id = value.id,
			name = value.name,
			state = M.state(value.status, value.conclusion),
			provider_state = provider_state(value),
			url = service.absolute_url(value.html_url),
			started_at = started_at,
			completed_at = completed_at,
			duration = duration(started_at, completed_at),
			steps = steps,
		})
	end
	return jobs
end

---@param base string
---@param run_id integer
---@param on_done fun(raw: table|nil, err: string|nil)
---@return { cancel: fun() }
local function fetch_jobs(base, run_id, on_done)
	local page, jobs = 1, {}
	local requests = request_scope.new()

	local fetch_page
	function fetch_page()
		local endpoint = string.format("%s/actions/runs/%d/jobs", base, run_id)
			.. service.query({ limit = 50, page = page })
		requests.run(function(done)
			return service.request("GET", endpoint, nil, done)
		end, function(raw, err)
			if err then
				on_done(nil, err)
				return
			end
			local values = raw.jobs
			local total = tonumber(raw.total_count)
			vim.list_extend(jobs, values)
			if #jobs >= total or #values == 0 then
				on_done({ total_count = total, jobs = jobs }, nil)
				return
			end
			page = page + 1
			fetch_page()
		end)
	end

	fetch_page()
	return requests
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param _opts table|nil
---@param on_done fun(pipeline: PullsPipeline|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_details(pr, pipeline, _opts, on_done)
	local run_id = M.parse_run_id(pr, pipeline)
	if run_id == nil then
		on_done(pipeline, nil)
		return nil
	end
	local base = repo_endpoint(pr)
	if base == nil then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end

	local requests = request_scope.new()
	requests.run(function(done)
		return service.request("GET", string.format("%s/actions/runs/%d", base, run_id), nil, done)
	end, function(run, err)
		if err then
			on_done(nil, err)
			return
		end
		requests.run(function(done)
			return fetch_jobs(base, run_id, done)
		end, function(raw, jobs_err)
			if jobs_err then
				on_done(nil, jobs_err)
				return
			end
			local jobs = map_jobs(raw)
			local result = vim.tbl_extend("force", {}, pipeline, {
				state = M.state(run.status, run.conclusion),
				provider_state = provider_state(run),
				url = pipeline.url,
				provider_id = tostring(run.id),
				commit_hash = run.head_sha,
				jobs = jobs,
			})
			on_done(result, nil)
		end)
	end)

	return requests
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(log: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_job_log(pr, pipeline, job, on_done)
	local base = repo_endpoint(pr)
	local job_id = tonumber(job.id)
	if base == nil or M.parse_run_id(pr, pipeline) == nil or job_id == nil then
		on_done(nil, "Invalid Gitea Actions job")
		return nil
	end
	return service.request_text("GET", string.format("%s/actions/jobs/%d/logs", base, job_id), on_done)
end

---@param pr PullRequest
---@param endpoint string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function post_action(pr, endpoint, on_done)
	local base = repo_endpoint(pr)
	if base == nil then
		on_done(false, "Invalid Gitea repository")
		return nil
	end
	return service.request("POST", base .. endpoint, nil, function(_, err)
		on_done(err == nil, err)
	end)
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param failed_only boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.rerun(pr, pipeline, failed_only, on_done)
	local run_id = M.parse_run_id(pr, pipeline)
	if run_id == nil then
		on_done(false, "Invalid Gitea Actions run")
		return nil
	end
	local action = failed_only and "rerun-failed-jobs" or "rerun"
	return post_action(pr, string.format("/actions/runs/%d/%s", run_id, action), on_done)
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.rerun_job(pr, pipeline, job, on_done)
	local run_id = M.parse_run_id(pr, pipeline)
	local job_id = tonumber(job.id)
	if run_id == nil or job_id == nil then
		on_done(false, "Invalid Gitea Actions job")
		return nil
	end
	return post_action(pr, string.format("/actions/runs/%d/jobs/%d/rerun", run_id, job_id), on_done)
end

return M
