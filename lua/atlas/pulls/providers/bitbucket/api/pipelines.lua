local M = {}

local pipeline_utils = require("atlas.pulls.pipelines")
local service = require("atlas.pulls.providers.bitbucket.api.service")

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
---@return PullsPipelineState
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

---@param values table[]
---@return string status
---@return string|nil url
local function aggregate_statuses(values)
	if #values == 0 then
		return "unknown", nil
	end

	local statuses = {}
	local first_url
	for _, item in ipairs(values) do
		table.insert(statuses, { state = pipeline_state(item.state) })
		if first_url == nil and item.url and item.url ~= "" then
			first_url = tostring(item.url)
		end
	end

	return pipeline_utils.aggregate_state(statuses):lower(), first_url
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
			started_at = job.started_on,
			duration = tonumber(job.duration_in_seconds),
		})
	end
	return jobs
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
	---@cast pr BitbucketPullRequest
	local statuses_url = tostring(pr.links.statuses or "")
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

	return service.fetch_all_values(url, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		---@type PullsPipeline[]
		local pipelines = {}
		for index, status in ipairs((result or {}).values or {}) do
			local pipeline_url = tostring(status.url or "")
			local status_id = tostring(status.key or "")
			if status_id == "" then
				status_id = tostring(status.name or index)
			end
			local id = pipeline_id(pipeline_url) or ("status:" .. status_id)
			local state = pipeline_state(status.state)
			table.insert(pipelines, {
				id = id,
				name = tostring(status.name or status.key or ""),
				state = state,
				url = pipeline_url ~= "" and pipeline_url or nil,
				stages = {},
			})
		end

		service.set_cache(key, pipelines)
		on_done(pipelines, nil)
	end, { action = "Fetch PR pipelines", repo = pr.repo_full_name, id = pr.id })
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(pipeline: PullsPipeline|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_details(pr, pipeline, _opts, on_done)
	local repo = tostring(pr.repo_full_name or "")
	local id = tostring(pipeline.id)
	if not id:match("^%d+$") then
		on_done(pipeline, nil)
		return nil
	end
	if repo == "" then
		on_done(nil, "Missing repo")
		return nil
	end

	local fields = "values.uuid,values.name,values.state,values.started_on,values.duration_in_seconds,next"
	local endpoint = string.format("/repositories/%s/pipelines/%s/steps?pagelen=100&fields=%s", repo, id, fields)
	return service.fetch_all_values(endpoint, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local jobs = parse_jobs(result)
		local detailed = vim.tbl_extend("force", {}, pipeline)
		detailed.stages = {
			{
				name = nil,
				state = pipeline_utils.aggregate_state(jobs),
				jobs = jobs,
			},
		}
		on_done(detailed, nil)
	end, { action = "Fetch pipeline details", repo = repo, pipeline_id = id })
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(log: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_job_log(pr, pipeline, job, on_done)
	local repo = tostring(pr.repo_full_name or "")
	local id = tostring(pipeline.id)
	local job_id = job.id
	if repo == "" or not id:match("^%d+$") or job_id == "" then
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
	local branch = tostring(pr.source.branch or "")
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
	local id = tostring(pipeline.id)
	if repo == "" or not id:match("^%d+$") then
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
			on_done(cached.status, cached.url, nil)
			return nil
		end
	end

	return service.fetch_all_values(url, function(result, err)
		if err then
			on_done(nil, nil, err)
			return
		end

		local values = (result or {}).values or {}
		local status, first_url = aggregate_statuses(values)
		service.set_cache(key, { status = status, url = first_url }, service.cache_ttl())
		on_done(status, first_url, nil)
	end, { action = "Fetch commit status", commit_hash = commit.hash })
end

return M
