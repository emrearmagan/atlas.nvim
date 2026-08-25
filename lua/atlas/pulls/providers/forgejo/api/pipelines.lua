local pipeline_utils = require("atlas.pulls.pipelines")
local service = require("atlas.providers.forgejo.client")
local pullrequests = require("atlas.pulls.providers.forgejo.api.pullrequests")
local request_scope = require("atlas.core.requests")

local M = {}

---@param slug string|nil
---@param value string|nil
---@return string|nil run_number, string|nil run_url
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
	local run_number, tail = url:sub(#prefix + 1):match("^(%d+)(.*)$")
	if not run_number or (tail ~= "" and tail ~= "/" and not tail:match("^/jobs/%d+/?$")) then
		return nil, nil
	end
	return run_number, prefix .. run_number
end

---@param value string|nil
---@return PullsPipelineState
function M.state(value)
	local state = tostring(value or ""):lower()
	if state == "success" then
		return "SUCCESSFUL"
	elseif state == "failure" or state == "error" then
		return "FAILED"
	elseif state == "pending" or state == "waiting" or state == "running" or state == "blocked" then
		return "INPROGRESS"
	elseif state == "warning" or state == "skipped" or state == "cancelled" or state == "canceled" then
		return "STOPPED"
	end
	return "UNKNOWN"
end

---@param started_at string|nil
---@param completed_at string|nil
---@return number|nil
local function duration(started_at, completed_at)
	if started_at == nil or completed_at == nil then
		return nil
	end
	local started = vim.fn.strptime("%Y-%m-%dT%H:%M:%SZ", tostring(started_at or ""))
	local completed = vim.fn.strptime("%Y-%m-%dT%H:%M:%SZ", tostring(completed_at or ""))
	if started <= 0 or completed < started then
		return nil
	end
	return completed - started
end

---@param raw table
---@param index integer
---@return PullsPipeline
local function external_pipeline(raw, index)
	local context = tostring(raw.context or "")
	local provider_id = tostring(raw.id or "")
	local name = context ~= "" and context or tostring(raw.description or "")
	local id = provider_id ~= "" and ("status:" .. provider_id)
		or string.format("status:%s:%d", name ~= "" and name or "external", index)
	return {
		id = id,
		name = name ~= "" and name or "Commit status",
		state = M.state(raw.status),
		provider_state = tostring(raw.status or ""),
		url = service.absolute_url(raw.target_url),
		stages = {},
	}
end

---@param result table[]
---@param _sha string
---@param slug string|nil
---@return PullsPipeline[]
function M.map(result, _sha, slug)
	local pipelines = {}
	local actions_runs = {}

	for index, raw in ipairs(result) do
		local target_url = service.absolute_url(raw.target_url)
		local run_number, run_url = M.actions_run(slug, target_url)
		if not run_number then
			table.insert(pipelines, external_pipeline(raw, index))
		else
			local context = tostring(raw.context or "")
			local workflow, job_name = context:match("^(.-)%s+/%s+(.+)$")
			local pipeline = actions_runs[run_number]
			if not pipeline then
				pipeline = {
					id = run_number,
					name = workflow or ("Actions run #" .. run_number),
					state = "UNKNOWN",
					provider_state = "",
					url = run_url,
					job_count = 0,
					stages = {
						{ name = nil, state = "UNKNOWN", jobs = {} },
					},
				}
				actions_runs[run_number] = pipeline
				table.insert(pipelines, pipeline)
			end

			local provider_state = tostring(raw.status or "")
			local job_id = target_url and target_url:match("/jobs/(%d+)")
				or string.format("summary:%s:%s:%d", run_number, tostring(raw.id or context), index)
			table.insert(pipeline.stages[1].jobs, {
				id = job_id,
				name = job_name or (context ~= "" and context or "Job"),
				state = M.state(provider_state),
				provider_state = provider_state,
				url = target_url,
			})
		end
	end

	for _, pipeline in ipairs(pipelines) do
		local stage = pipeline.stages[1]
		if stage then
			stage.state = #stage.jobs > 0 and pipeline_utils.aggregate_state(stage.jobs) or "UNKNOWN"
			pipeline.state = stage.state
			pipeline.job_count = #stage.jobs
			for _, job in ipairs(stage.jobs) do
				if job.state == pipeline.state then
					pipeline.provider_state = job.provider_state
					break
				end
			end
		end
	end
	return pipelines
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
	opts = opts or {}
	local requests = request_scope.new()

	---@param selected PullRequest
	local function fetch_statuses(selected)
		local sha = tostring(selected.source.commit_hash or "")
		local owner, repo = selected.repo_full_name:match("^([^/]+)/([^/]+)$")
		if not owner or sha == "" then
			on_done(nil, "Invalid Forgejo repository or source commit")
			return
		end
		local endpoint = string.format(
			"/repos/%s/%s/commits/%s/status",
			service.url_encode(owner),
			service.url_encode(repo),
			service.url_encode(sha)
		)
		requests.run(function(done)
			return service.request("GET", endpoint, nil, done)
		end, function(raw, err)
			if err then
				on_done(nil, err)
				return
			end
			local statuses = type(raw.statuses) == "table" and raw.statuses or {}
			on_done(M.map(statuses, sha, selected.repo_full_name), nil)
		end)
	end

	if tostring(pr.source.commit_hash or "") ~= "" then
		fetch_statuses(pr)
		return requests
	end

	-- Global Forgejo search omits the source SHA, so load the selected PR first.
	requests.run(function(done)
		return pullrequests.fetch_by_refs({ pr }, { force_load = opts.force_refresh }, done)
	end, function(pulls, err)
		local selected = pulls and pulls[1] or nil
		if selected == nil then
			on_done(nil, err or "Unable to load Forgejo pull request revisions")
			return
		end
		fetch_statuses(selected)
	end)
	return requests
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

	return service.request("GET", endpoint, nil, function(raw, err)
		if err then
			on_done(nil, nil, err)
			return
		end
		local statuses = type(raw.statuses) == "table" and raw.statuses or {}
		local pipelines = M.map(statuses, commit.hash, nil)
		local url
		for _, pipeline in ipairs(pipelines) do
			url = url or pipeline.url
		end
		on_done(pipeline_utils.aggregate_state(pipelines):lower(), url, nil)
	end)
end

---@param pr PullRequest
---@return string|nil
local function repo_endpoint(pr)
	local owner, repo = pr.repo_full_name:match("^([^/]+)/([^/]+)$")
	if owner then
		return string.format("/repos/%s/%s", service.url_encode(owner), service.url_encode(repo))
	end
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@return string|nil
function M.parse_run_number(pr, pipeline)
	return M.actions_run(pr.repo_full_name, pipeline.url)
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param on_done fun(run: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function resolve_run(pr, pipeline, on_done)
	local base = repo_endpoint(pr)
	local run_number = M.parse_run_number(pr, pipeline)
	if not base or not run_number then
		on_done(nil, "Invalid Forgejo Actions run")
		return nil
	end
	local sha = tostring(pr.source.commit_hash or "")
	return service.request("GET", base .. "/actions/runs" .. service.query({
		run_number = run_number,
		head_sha = sha ~= "" and sha or nil,
		limit = 1,
	}), nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local runs = type(raw.workflow_runs) == "table" and raw.workflow_runs or {}
		local run = runs[1]
		if
			not run
			or tostring(run.index_in_repo or "") ~= run_number
			or (sha ~= "" and tostring(run.commit_sha or "") ~= sha)
		then
			on_done(nil, "Forgejo Actions run not found")
			return
		end
		on_done(run, nil)
	end)
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param _opts table|nil
---@param on_done fun(pipeline: PullsPipeline|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_details(pr, pipeline, _opts, on_done)
	local base = repo_endpoint(pr)
	if not base or not M.parse_run_number(pr, pipeline) then
		on_done(pipeline, nil)
		return nil
	end
	local requests = request_scope.new()
	requests.run(function(done)
		return resolve_run(pr, pipeline, done)
	end, function(run, err)
		if err then
			on_done(nil, err)
			return
		end
		local run_id = tostring(run.id)
		requests.run(function(done)
			return service.request("GET", string.format("%s/actions/runs/%s/jobs", base, run_id), nil, done)
		end, function(raw, jobs_err)
			if jobs_err then
				on_done(nil, jobs_err)
				return
			end
			local jobs = {}
			for index, job in ipairs(raw) do
				local job_id = tostring(job.id or "")
				table.insert(jobs, {
					id = job_id ~= "" and job_id or string.format("job:%s:%d", run_id, index),
					name = tostring(job.name or "Job"),
					state = M.state(job.status),
					provider_state = tostring(job.status or ""),
					url = service.absolute_url(job.html_url),
					started_at = job.started_at,
					duration = duration(job.started_at, job.completed_at),
				})
			end
			local stage_state = #jobs > 0 and pipeline_utils.aggregate_state(jobs) or M.state(run.status)
			local detailed = vim.tbl_extend("force", {}, pipeline)
			detailed.name = tostring(run.name or "") ~= "" and tostring(run.name) or pipeline.name
			detailed.state = M.state(run.status)
			detailed.provider_state = tostring(run.status or "")
			detailed.job_count = #jobs
			detailed.stages = {
				{ name = nil, state = stage_state, jobs = jobs },
			}
			on_done(detailed, nil)
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
	local job_id = tostring(job.id)
	if not base or not job_id:match("^%d+$") or not M.parse_run_number(pr, pipeline) then
		on_done(nil, "Invalid Forgejo Actions job")
		return nil
	end
	return service.request_text("GET", string.format("%s/actions/jobs/%s/logs", base, job_id), on_done)
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.cancel(pr, pipeline, on_done)
	local base = repo_endpoint(pr)
	if not base or not M.parse_run_number(pr, pipeline) then
		on_done(false, "Invalid Forgejo Actions run")
		return nil
	end
	local requests = request_scope.new()
	requests.run(function(done)
		return resolve_run(pr, pipeline, done)
	end, function(run, err)
		if err then
			on_done(false, err)
			return
		end
		requests.run(function(done)
			return service.request("POST", string.format("%s/actions/runs/%s/cancel", base, run.id), nil, done)
		end, function(_, cancel_err)
			on_done(cancel_err == nil, cancel_err)
		end)
	end)
	return requests
end

return M
