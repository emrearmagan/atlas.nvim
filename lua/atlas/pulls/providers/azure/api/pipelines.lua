---@class AzurePipelineStage : PullsPipelineStage
---@field ref_name string|nil

---@class AzurePipelineJob : PullsPipelineJob
---@field log_ids integer[]

local M = {}

local json = require("atlas.core.json")
local pipeline_utils = require("atlas.pulls.pipelines")
local request_scope = require("atlas.core.requests")
local service = require("atlas.pulls.providers.azure.api.service")

local states = {
	pending = "INPROGRESS",
	notStarted = "INPROGRESS",
	postponed = "INPROGRESS",
	inProgress = "INPROGRESS",
	cancelling = "INPROGRESS",
	succeeded = "SUCCESSFUL",
	succeededWithIssues = "SUCCESSFUL",
	partiallySucceeded = "FAILED",
	failed = "FAILED",
	error = "FAILED",
	canceled = "STOPPED",
	skipped = "STOPPED",
	abandoned = "STOPPED",
	notApplicable = "STOPPED",
}

---@param status string
---@param result string|nil
---@return PullsPipelineState
local function pipeline_state(status, result)
	return states[status == "completed" and json.safe_str(result) or status] or "UNKNOWN"
end

---@param pr PullRequest
---@return string
local function builds_endpoint(pr)
	return "/" .. service.url_encode(pr.workspace) .. "/_apis/build/builds"
end

---@param raw table
---@return PullsPipeline
local function to_pipeline(raw)
	return {
		id = tostring(raw.id),
		name = raw.definition.name .. " #" .. raw.buildNumber,
		state = pipeline_state(raw.status, raw.result),
		provider_state = json.safe_str(raw.result) or raw.status,
		url = raw._links.web.href,
		stages = {},
	}
end

---@param pr AzurePullRequest
---@param branch string
---@param reason string|nil
---@param on_done fun(builds: table[]|nil, err: string|nil)
---@return AtlasRequestScope
local function fetch_builds(pr, branch, reason, on_done)
	local scope = request_scope.new()
	local builds = {}
	local function fetch_page(continuation_token)
		local query = service.build_query({
			branchName = branch,
			reasonFilter = reason,
			repositoryId = pr.repository_id,
			repositoryType = "TfsGit",
			queryOrder = "queueTimeDescending",
			maxBuildsPerDefinition = 1,
			["$top"] = 100,
			continuationToken = continuation_token,
		})
		scope.run(function(done)
			return service.request("GET", builds_endpoint(pr) .. query, nil, done, {
				action = "Fetch pull request builds",
				repo = pr.repo_full_name,
				id = pr.id,
			})
		end, function(result, err, headers)
			if err then
				on_done(nil, err)
				return
			end
			vim.list_extend(builds, result.value)
			local next_token = headers["x-ms-continuationtoken"]
			if next_token then
				fetch_page(next_token)
				return
			end
			on_done(builds, nil)
		end)
	end
	fetch_page(nil)
	return scope
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return AtlasRequestScope|nil
function M.fetch(pr, opts, on_done)
	---@cast pr AzurePullRequest
	local cache_key = string.format(
		"pipelines:%s:%s:%s:%s",
		pr.repo_full_name,
		pr.id,
		pr.source.commit_hash,
		pr.merge_commit_hash or ""
	)
	if not (opts or {}).force_refresh then
		local cached, found = service.get_cache(cache_key)
		if found then
			on_done(cached, nil)
			return nil
		end
	end
	local scope = request_scope.new()
	scope.all({
		pullrequest = function(done)
			return fetch_builds(pr, "refs/pull/" .. pr.id .. "/merge", "pullRequest", done)
		end,
		branch = function(done)
			return fetch_builds(pr, "refs/heads/" .. pr.source.branch, nil, done)
		end,
	}, function(results, errors)
		local err = errors.pullrequest or errors.branch
		if err then
			on_done(nil, err)
			return
		end
		local builds = {}
		for _, build in ipairs(results.pullrequest) do
			if build.sourceVersion == pr.merge_commit_hash then
				table.insert(builds, build)
			end
		end
		for _, build in ipairs(results.branch) do
			if build.sourceVersion == pr.source.commit_hash then
				table.insert(builds, build)
			end
		end
		table.sort(builds, function(left, right)
			return left.queueTime > right.queueTime
		end)
		local pipelines = {}
		for _, build in ipairs(builds) do
			table.insert(pipelines, to_pipeline(build))
		end
		service.set_cache(cache_key, pipelines)
		on_done(pipelines, nil)
	end)
	return scope
end

---@param started_at string|nil
---@param finished_at string|nil
---@return number|nil
local function duration(started_at, finished_at)
	if not started_at or not finished_at then
		return nil
	end
	return vim.fn.strptime("%Y-%m-%dT%H:%M:%S", finished_at:sub(1, 19))
		- vim.fn.strptime("%Y-%m-%dT%H:%M:%S", started_at:sub(1, 19))
end

---@param pipeline PullsPipeline
---@param records table[]
---@return PullsPipeline
local function with_timeline(pipeline, records)
	local by_id = {}
	local stages = {}
	local stages_by_id = {}
	local job_records = {}
	local jobs_by_id = {}
	local ungrouped = { state = "UNKNOWN", jobs = {} }
	table.sort(records, function(left, right)
		return (left.order or 0) < (right.order or 0)
	end)
	for _, raw in ipairs(records) do
		by_id[raw.id] = raw
		if raw.type == "Stage" then
			local stage = {
				name = raw.identifier ~= "__default" and raw.name or nil,
				ref_name = raw.identifier,
				state = pipeline_state(raw.state, raw.result),
				jobs = {},
			}
			stages_by_id[raw.id] = stage
			table.insert(stages, stage)
		elseif raw.type == "Job" then
			table.insert(job_records, raw)
		end
	end
	table.sort(job_records, function(left, right)
		local left_parent = by_id[left.parentId]
		local right_parent = by_id[right.parentId]
		local left_order = left_parent and left_parent.order or 0
		local right_order = right_parent and right_parent.order or 0
		if left_order ~= right_order then
			return left_order < right_order
		end
		return left.order < right.order
	end)
	for _, raw in ipairs(job_records) do
		local parent = by_id[raw.parentId]
		local stage_id = parent and (parent.type == "Phase" and parent.parentId or parent.id)
		local stage = stages_by_id[stage_id] or ungrouped
		local job = {
			id = raw.id,
			name = raw.name,
			state = pipeline_state(raw.state, raw.result),
			provider_state = json.safe_str(raw.result) or raw.state,
			url = pipeline.url,
			started_at = json.safe_str(raw.startTime),
			duration = duration(json.safe_str(raw.startTime), json.safe_str(raw.finishTime)),
			log_ids = {},
		}
		jobs_by_id[raw.id] = job
		table.insert(stage.jobs, job)
	end
	for _, raw in ipairs(records) do
		local job = jobs_by_id[raw.parentId]
		if job and raw.type == "Task" and json.nilify(raw.log) then
			table.insert(job.log_ids, raw.log.id)
		end
	end
	if #ungrouped.jobs > 0 then
		ungrouped.state = pipeline_utils.aggregate_state(ungrouped.jobs)
		table.insert(stages, ungrouped)
	end
	return vim.tbl_extend("force", {}, pipeline, { stages = stages, job_count = #job_records })
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(pipeline: PullsPipeline|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_details(pr, pipeline, opts, on_done)
	local endpoint = builds_endpoint(pr) .. "/" .. pipeline.id .. "/timeline"
	local cache_key = "pipeline:" .. endpoint
	if not (opts or {}).force_refresh then
		local cached, found = service.get_cache(cache_key)
		if found then
			on_done(with_timeline(pipeline, cached), nil)
			return nil
		end
	end
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		service.set_cache(cache_key, result.records)
		on_done(with_timeline(pipeline, result.records), nil)
	end, { action = "Fetch build timeline", pipeline_id = pipeline.id })
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(log: string|nil, err: string|nil)
---@return AtlasRequestScope
function M.fetch_job_log(pr, pipeline, job, on_done)
	---@cast job AzurePipelineJob
	local starts = {}
	for _, log_id in ipairs(job.log_ids) do
		local endpoint = builds_endpoint(pr) .. "/" .. pipeline.id .. "/logs/" .. log_id
		table.insert(starts, function(done)
			return service.request("GET", endpoint, nil, done, {
				action = "Fetch build job log",
				pipeline_id = pipeline.id,
				job_id = job.id,
			})
		end)
	end
	local scope = request_scope.new()
	scope.all(starts, function(results, errors)
		local logs = {}
		for index = 1, #starts do
			if errors[index] then
				on_done(nil, errors[index])
				return
			end
			table.insert(logs, table.concat(results[index].value, "\n"))
		end
		on_done(table.concat(logs, "\n"), nil)
	end)
	return scope
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.cancel(pr, pipeline, on_done)
	return service.request(
		"PATCH",
		builds_endpoint(pr) .. "/" .. pipeline.id,
		{ status = "cancelling" },
		function(_, err)
			if err then
				on_done(false, err)
				return
			end
			service.clear_cache()
			on_done(true, nil)
		end,
		{ action = "Cancel build", pipeline_id = pipeline.id }
	)
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param stage AzurePipelineStage
---@param action "retry"|"cancel"
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_stage(pr, pipeline, stage, action, on_done)
	local endpoint = builds_endpoint(pr) .. "/" .. pipeline.id .. "/stages/" .. service.url_encode(stage.ref_name)
	return service.request("PATCH", endpoint, {
		state = action,
		forceRetryAllJobs = action == "retry" or nil,
	}, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.clear_cache()
		on_done(true, nil)
	end, { action = "Update build stage", pipeline_id = pipeline.id, stage = stage.ref_name })
end

---@param commit PullsCommit
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(status: string|nil, url: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commit_status(commit, opts, on_done)
	if not commit.statuses_url then
		on_done("unknown", nil, nil)
		return nil
	end
	local endpoint = commit.statuses_url .. service.build_query({ latestOnly = true })
	local cache_key = "commit-status:" .. endpoint
	if not (opts or {}).force_refresh then
		local cached, found = service.get_cache(cache_key)
		if found then
			on_done(cached.status, cached.url, nil)
			return nil
		end
	end
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, nil, err)
			return
		end
		local statuses = {}
		for _, raw in ipairs(result.value) do
			table.insert(statuses, { state = states[raw.state] or "UNKNOWN" })
		end
		local status = pipeline_utils.aggregate_state(statuses):lower()
		local url = result.value[1] and json.safe_str(result.value[1].targetUrl) or nil
		service.set_cache(cache_key, { status = status, url = url })
		on_done(status, url, nil)
	end, { action = "Fetch commit status", commit_hash = commit.hash })
end

return M
