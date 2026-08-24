local M = {}

local providers = require("atlas.pulls.providers")
local service = require("atlas.pulls.providers.bitbucket.api.service")

---@param values table[]
---@return string status
---@return string|nil url
local function aggregate_statuses(values)
	if #values == 0 then
		return "unknown", nil
	end

	local first_url = nil
	for _, item in ipairs(values) do
		if not first_url and item.url and item.url ~= "" then
			first_url = tostring(item.url)
		end
	end

	return providers.aggregate_pipeline_state(values):lower(), first_url
end

---@param url string
---@return string|nil
local function pipeline_id(url)
	return url:match("/pipelines/results/(%d+)")
end

---@param state any
---@return string
local function provider_state(state)
	if type(state) ~= "table" then
		return tostring(state or "")
	end
	local result = type(state.result) == "table" and state.result.name or nil
	return tostring(result or state.name or "")
end

---@param state any
---@return "SUCCESSFUL"|"FAILED"|"INPROGRESS"|"STOPPED"|"UNKNOWN"
local function pipeline_state(state)
	local value = provider_state(state):upper()
	if value == "SUCCESSFUL" then
		return "SUCCESSFUL"
	elseif value == "FAILED" or value == "ERROR" then
		return "FAILED"
	elseif value == "STOPPED" or value == "EXPIRED" or value == "SUPERSEDED" then
		return "STOPPED"
	end

	local name = type(state) == "table" and tostring(state.name or ""):upper() or value
	if name == "PENDING" or name == "IN_PROGRESS" then
		return "INPROGRESS"
	end
	return "UNKNOWN"
end

---@param value string
---@return string
local function encode_path_segment(value)
	return (value:gsub("[^%w%-._~]", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

---@param result table|nil
---@return PullsPipelineJob[]
local function parse_jobs(result)
	local jobs = {}
	for index, job in ipairs((result or {}).values or {}) do
		table.insert(jobs, {
			id = tostring(job.uuid or index),
			name = tostring(job.name or "Job"),
			state = pipeline_state(job.state),
			provider_state = provider_state(job.state),
			started_at = job.started_on,
			completed_at = job.completed_on,
			duration = tonumber(job.duration_in_seconds),
			steps = {},
		})
	end
	return jobs
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pipelines(pr, opts, on_done)
	---@cast pr BitbucketPullRequest
	local statuses_url = tostring(pr.links.statuses or "")
	local commit_hash = tostring((pr.source or {}).commit_hash or "")
	if statuses_url == "" then
		on_done({}, nil)
		return nil
	end

	local fields = "values.name,values.key,values.state,values.url,next"
	local sep = statuses_url:find("?") and "&" or "?"
	local url = string.format("%s%spagelen=%d&fields=%s", statuses_url, sep, 100, fields)
	local key = "bitbucket:pr:pipelines:" .. url
	if not (opts or {}).force_refresh then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local cancelled = false
	local handles = {}
	local function track(handle)
		if handle then
			table.insert(handles, handle)
		end
	end

	track(service.fetch_all_values(url, function(result, err)
		if cancelled then
			return
		end
		if err then
			on_done(nil, err)
			return
		end

		---@type PullsPipeline[]
		local pipelines = {}
		local pipeline_jobs = {}
		for _, status in ipairs((result or {}).values or {}) do
			local pipeline_url = tostring(status.url or "")
			local id = pipeline_id(pipeline_url)
			local pipeline = {
				name = tostring(status.name or status.key or ""),
				state = tostring(status.state or ""):upper(),
				provider_state = tostring(status.state or ""),
				url = pipeline_url ~= "" and pipeline_url or nil,
				key = tostring(status.key or ""),
				provider_id = id,
				commit_hash = commit_hash,
				jobs = {},
			}
			table.insert(pipelines, pipeline)
			if id then
				table.insert(pipeline_jobs, pipeline)
			end
		end

		if #pipeline_jobs == 0 then
			service.set_cache(key, pipelines)
			on_done(pipelines, nil)
			return
		end

		local repo = tostring(pr.repo_full_name or "")
		if repo == "" then
			on_done(nil, "Missing repo")
			return
		end

		local pending = #pipeline_jobs
		local first_err
		for _, pipeline in ipairs(pipeline_jobs) do
			local endpoint =
				string.format("/repositories/%s/pipelines/%s/steps?pagelen=100", repo, pipeline.provider_id)
			track(service.request("GET", endpoint, nil, nil, function(jobs, jobs_err)
				if cancelled then
					return
				end
				if jobs_err then
					first_err = first_err or tostring(jobs_err)
				else
					pipeline.jobs = parse_jobs(jobs)
				end
				pending = pending - 1
				if pending == 0 then
					if not first_err then
						service.set_cache(key, pipelines)
					end
					on_done(first_err and nil or pipelines, first_err)
				end
			end))
		end
	end))

	return {
		cancel = function()
			cancelled = true
			for _, handle in ipairs(handles) do
				if type(handle.cancel) == "function" then
					handle.cancel()
				end
			end
		end,
	}
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(log: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pipeline_job_log(pr, pipeline, job, on_done)
	local repo = tostring(pr.repo_full_name or "")
	local id = tostring(pipeline.provider_id or pipeline_id(tostring(pipeline.url or "")) or "")
	local job_id = tostring(job.id or "")
	if repo == "" or id == "" or job_id == "" then
		on_done(nil, "Missing Bitbucket pipeline job identifier")
		return nil
	end

	local endpoint = string.format("/repositories/%s/pipelines/%s/steps/%s/log", repo, id, encode_path_segment(job_id))
	return service.request_text("GET", endpoint, { Accept = "*/*" }, nil, on_done, {
		action = "Fetch pipeline job log",
		repo = repo,
		pipeline_id = id,
		job_id = job_id,
	})
end

---@param pr PullRequest
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.run_pipeline(pr, on_done)
	local repo = tostring(pr.repo_full_name or "")
	local branch = tostring((pr.source or {}).branch or "")
	if repo == "" or branch == "" then
		on_done(false, repo == "" and "Missing repo" or "Missing source branch")
		return nil
	end

	local body = vim.json.encode({
		target = {
			type = "pipeline_ref_target",
			ref_type = "branch",
			ref_name = branch,
		},
	})
	return service.request("POST", string.format("/repositories/%s/pipelines/", repo), nil, body, function(_, err)
		on_done(err == nil, err)
	end, { action = "Run pipeline", repo = repo, branch = branch })
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.stop_pipeline(pr, pipeline, on_done)
	local repo = tostring(pr.repo_full_name or "")
	local id = tostring(pipeline.provider_id or pipeline_id(tostring(pipeline.url or "")) or "")
	if repo == "" or id == "" then
		on_done(false, "Missing Bitbucket pipeline identifier")
		return nil
	end

	local endpoint = string.format("/repositories/%s/pipelines/%s/stopPipeline", repo, id)
	return service.request("POST", endpoint, nil, nil, function(_, err)
		on_done(err == nil, err)
	end, { action = "Stop pipeline", repo = repo, pipeline_id = id })
end

---@param commit PullsCommit
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(status: string|nil, url: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commit_status(commit, opts, on_done)
	local statuses_url = tostring(commit.statuses_url or "")
	if statuses_url == "" then
		on_done("unknown", nil, nil)
		return nil
	end

	local force = (opts or {}).force_refresh == true
	local sep = statuses_url:find("?") and "&" or "?"
	local url = string.format("%s%spagelen=%d", statuses_url, sep, 30)
	local key = "bitbucket:commit:statuses:" .. url
	if not force then
		local cached, ok = service.get_cache(key)
		if ok then
			local entries = (cached or {}).values or cached or {}
			local status, first_url = aggregate_statuses(entries)
			on_done(status, first_url, nil)
			return nil
		end
	end

	return service.request("GET", url, nil, nil, function(result, err)
		if err then
			on_done(nil, nil, err)
			return
		end

		service.set_cache(key, result, service.cache_ttl())
		local values = (result or {}).values or {}
		local status, first_url = aggregate_statuses(values)
		on_done(status, first_url, nil)
	end)
end

return M
