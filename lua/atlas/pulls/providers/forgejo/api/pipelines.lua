local pagination = require("atlas.providers.forgejo.pagination").pulls
local providers = require("atlas.pulls.providers")
local service = require("atlas.providers.forgejo.client").pulls
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
---@return "SUCCESSFUL"|"FAILED"|"INPROGRESS"|"STOPPED"|"UNKNOWN"
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
		local run_number, run_url = M.actions_run(slug, target_url)
		if not run_number then
			table.insert(pipelines, external_pipeline(raw, sha))
		else
			local context = raw.context or ""
			local workflow, job_name = context:match("^(.-)%s+/%s+(.+)$")
			local pipeline = actions_runs[run_number]
			if not pipeline then
				pipeline = {
					name = workflow or ("Actions run #" .. run_number),
					state = "UNKNOWN",
					url = run_url,
					key = workflow or run_number,
					commit_hash = sha,
					jobs = {},
				}
				actions_runs[run_number] = pipeline
				table.insert(pipelines, pipeline)
			end

			local provider_state = raw.status
			table.insert(pipeline.jobs, {
				id = raw.id,
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
		on_done(nil, "Invalid Forgejo repository or source commit")
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
	local sha = tostring(pipeline.commit_hash or "")
	return service.request("GET", base .. "/actions/runs" .. service.query({
		run_number = run_number,
		head_sha = sha ~= "" and sha or nil,
		limit = 1,
	}), nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local runs = raw.workflow_runs
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
			for _, job in ipairs(raw) do
				table.insert(jobs, {
					id = job.id,
					name = job.name,
					state = M.state(job.status),
					provider_state = job.status,
					url = nil,
					steps = {},
				})
			end
			local result = vim.tbl_extend("force", {}, pipeline, {
				name = pipeline.name,
				state = M.state(run.status),
				provider_state = run.status,
				url = pipeline.url,
				provider_id = tostring(run.id),
				commit_hash = run.commit_sha,
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
