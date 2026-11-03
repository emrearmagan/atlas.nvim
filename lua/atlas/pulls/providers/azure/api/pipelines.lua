---@class AzurePipeline : PullsPipeline
---@field provider_state string
---@field definition_id integer
---@field repository_id string

---@class AzurePipelineStage : PullsPipelineStage
---@field ref_name string|nil

---@class AzurePipelineJob : PullsPipelineJob
---@field log_ids integer[]

local M = {}

local json = require("atlas.core.json")
local pipeline_utils = require("atlas.pulls.pipelines.utils")
local request_scope = require("atlas.core.requests")
local service = require("atlas.providers.azure.client")

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

---@param context PullsPipelineContext
---@return string
local function project_endpoint(context)
	return "/" .. service.url_encode(context.repo_full_name:match("^[^/]+"))
end

---@param context PullsPipelineContext
---@return string
local function builds_endpoint(context)
	return project_endpoint(context) .. "/_apis/build/builds"
end

---@param raw table
---@return AzurePipeline
local function to_pipeline(raw)
	local branch = json.safe_str(raw.sourceBranch)
	local reason = json.safe_str(raw.reason)
	local started_at = json.safe_str(raw.startTime)

	return {
		id = tostring(raw.id),
		name = raw.definition.name .. " #" .. raw.buildNumber,
		state = pipeline_state(raw.status, raw.result),
		provider_state = json.safe_str(raw.result) or raw.status,
		url = raw._links.web.href,
		commit = json.safe_str(raw.sourceVersion),
		branch = branch and (branch:gsub("^refs/heads/", "")),
		trigger = reason and reason:gsub("(%l)(%u)", "%1 %2"):lower(),
		started_at = started_at or json.safe_str(raw.queueTime),
		duration = pipeline_utils.duration(started_at, json.safe_str(raw.finishTime)),
		definition_id = raw.definition.id,
		repository_id = raw.repository.id,
		stages = {},
	}
end

---@param context PullsPipelineContext
---@param repository_id string
---@param branch string
---@param reason string|nil
---@param on_done fun(builds: table[]|nil, err: string|nil)
---@return AtlasRequestScope
local function fetch_builds(context, repository_id, branch, reason, on_done)
	return service.fetch_all(builds_endpoint(context), {
		branchName = branch,
		reasonFilter = reason,
		repositoryId = repository_id,
		repositoryType = "TfsGit",
		queryOrder = "queueTimeDescending",
		maxBuildsPerDefinition = 1,
	}, {
		action = "Fetch builds",
		repo = context.repo_full_name,
		branch = branch,
	}, on_done)
end

---@param context PullsPipelineContext
---@param on_done fun(id: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_repository_id(context, on_done)
	local repository = context.repo_full_name:match("^[^/]+/(.+)$")
	local endpoint = project_endpoint(context) .. "/_apis/git/repositories/" .. service.url_encode(repository)
	local cache_key = "repository-id:" .. endpoint
	local cached, found = service.get_cache(cache_key)
	if found then
		on_done(cached, nil)
		return nil
	end

	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		service.set_cache(cache_key, result.id)
		on_done(result.id, nil)
	end, { action = "Fetch repository", repo = context.repo_full_name })
end

---@param context PullsPipelineContext
---@param branch string
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return AtlasRequestScope
local function fetch_branch(context, branch, on_done)
	local scope = request_scope.new()
	scope.run(function(done)
		return fetch_repository_id(context, done)
	end, function(repository_id, err)
		if err then
			on_done(nil, err)
			return
		end

		scope.run(function(done)
			return fetch_builds(context, repository_id, "refs/heads/" .. branch, nil, done)
		end, function(builds, builds_err)
			if builds_err then
				on_done(nil, builds_err)
				return
			end

			local pipelines = {}
			for _, build in ipairs(builds) do
				table.insert(pipelines, to_pipeline(build))
			end
			on_done(pipelines, nil)
		end)
	end)
	return scope
end

---@param context PullsPipelineContext
---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return AtlasRequestScope|nil
local function fetch_pr(context, pr, opts, on_done)
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
			return fetch_builds(context, pr.repository_id, "refs/pull/" .. pr.id .. "/merge", "pullRequest", done)
		end,
		branch = function(done)
			return fetch_builds(context, pr.repository_id, "refs/heads/" .. pr.source.branch, nil, done)
		end,
	}, function(results, errors)
		local err = errors.pullrequest or errors.branch
		if err then
			on_done(nil, err)
			return
		end
		local builds = {}
		for _, build in ipairs(results.pullrequest) do
			table.insert(builds, build)
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
			url = pipeline.url,
			started_at = json.safe_str(raw.startTime),
			duration = pipeline_utils.duration(json.safe_str(raw.startTime), json.safe_str(raw.finishTime)),
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
	return vim.tbl_extend("force", {}, pipeline, { stages = stages })
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(pipeline: PullsPipeline|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_timeline(context, pipeline, opts, on_done)
	local endpoint = builds_endpoint(context) .. "/" .. pipeline.id .. "/timeline"
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

---@param context PullsPipelineContext
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return AtlasRequestScope|nil
function M.fetch(context, opts, on_done)
	local target = context.target
	local pr = type(target) == "table" and target.source and target or nil
	---@cast pr PullRequest|nil
	local branch = type(target) == "string" and target ~= "" and target or nil
	if not pr and not branch then
		on_done(nil, "Azure pipelines require a pull request or branch")
		return nil
	end

	local scope = request_scope.new()
	scope.run(function(done)
		if pr then
			return fetch_pr(context, pr, opts, done)
		end
		return fetch_branch(context, assert(branch), done)
	end, function(pipelines, err)
		if err then
			on_done(nil, err)
			return
		end
		local starts = {}
		for index, pipeline in ipairs(pipelines) do
			starts[index] = function(done)
				return fetch_timeline(context, pipeline, opts, done)
			end
		end
		scope.all(starts, function(results, errors)
			for index = 1, #pipelines do
				if errors[index] then
					on_done(nil, errors[index])
					return
				end
			end
			on_done(results, nil)
		end)
	end)
	return scope
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(pipeline: PullsPipeline|nil, err: string|nil)
---@return AtlasRequestScope|nil
function M.fetch_pipeline(context, pipeline, on_done)
	local scope = request_scope.new()
	scope.run(function(done)
		return service.request("GET", builds_endpoint(context) .. "/" .. pipeline.id, nil, done, {
			action = "Fetch build",
			pipeline_id = pipeline.id,
		})
	end, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		scope.run(function(done)
			return fetch_timeline(context, to_pipeline(result), { force_refresh = true }, done)
		end, on_done)
	end)
	return scope
end

---@param context PullsPipelineContext
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return AtlasRequestScope
function M.fetch_history(context, on_done)
	local target = context.target
	local scope = request_scope.new()

	local function fetch_runs(repository_id, branch)
		local query = service.build_query({
			branchName = branch,
			repositoryId = repository_id,
			repositoryType = "TfsGit",
			queryOrder = "queueTimeDescending",
			["$top"] = 30,
		})
		scope.run(function(done)
			return service.request("GET", builds_endpoint(context) .. query, nil, done, {
				action = "Fetch build history",
				repo = context.repo_full_name,
				branch = branch,
			})
		end, function(result, err)
			if err then
				on_done(nil, err)
				return
			end

			local pipelines = {}
			for _, build in ipairs(result.value) do
				table.insert(pipelines, to_pipeline(build))
			end
			on_done(pipelines, nil)
		end)
	end

	if type(target) == "string" then
		scope.run(function(done)
			return fetch_repository_id(context, done)
		end, function(repository_id, err)
			if err then
				on_done(nil, err)
				return
			end
			fetch_runs(repository_id, "refs/heads/" .. target)
		end)
	elseif target.source then
		---@cast target AzurePullRequest
		fetch_runs(target.repository_id, "refs/pull/" .. target.id .. "/merge")
	else
		---@cast target AzurePipeline
		local branch = target.branch or ""
		fetch_runs(target.repository_id, vim.startswith(branch, "refs/") and branch or "refs/heads/" .. branch)
	end
	return scope
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(file: { path: string, content: string }|nil, err: string|nil)
---@return AtlasRequestScope
function M.fetch_config(context, pipeline, on_done)
	---@cast pipeline AzurePipeline
	local project = project_endpoint(context)
	local scope = request_scope.new()
	scope.run(function(done)
		return service.request("GET", project .. "/_apis/build/definitions/" .. pipeline.definition_id, nil, done, {
			action = "Fetch build definition",
			pipeline_id = pipeline.id,
		})
	end, function(definition, err)
		if err then
			on_done(nil, err)
			return
		end

		local path = json.safe_str(json.safe_table(definition.process).yamlFilename)
		if not path then
			on_done(nil, "No configuration file for this pipeline")
			return
		end

		local query = service.build_query({
			path = path,
			includeContent = true,
			["versionDescriptor.version"] = pipeline.commit,
			["versionDescriptor.versionType"] = "commit",
		})
		scope.run(function(done)
			local endpoint = project .. "/_apis/git/repositories/" .. pipeline.repository_id .. "/items" .. query
			return service.request("GET", endpoint, nil, done, {
				action = "Fetch pipeline configuration",
				pipeline_id = pipeline.id,
				path = path,
			})
		end, function(item, item_err)
			on_done(item and { path = path, content = json.safe_str(item.content) or "" }, item_err)
		end)
	end)
	return scope
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(job: PullsPipelineJob|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_job(context, pipeline, job, on_done)
	return fetch_timeline(context, pipeline, { force_refresh = true }, function(updated, err)
		if not updated then
			on_done(nil, err)
			return
		end
		for _, stage in ipairs(updated.stages) do
			for _, current in ipairs(stage.jobs) do
				if current.id == job.id then
					on_done(current, nil)
					return
				end
			end
		end
		on_done(nil, "Build job no longer exists")
	end)
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(log: PullsLog|nil, err: string|nil)
---@return AtlasRequestScope
function M.fetch_job_log(context, pipeline, job, on_done)
	---@cast job AzurePipelineJob
	local starts = {}
	for _, log_id in ipairs(job.log_ids) do
		local endpoint = builds_endpoint(context) .. "/" .. pipeline.id .. "/logs/" .. log_id
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
		on_done({ raw = table.concat(logs, "\n") }, nil)
	end)
	return scope
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.cancel(context, pipeline, on_done)
	return service.request(
		"PATCH",
		builds_endpoint(context) .. "/" .. pipeline.id,
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

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param stage AzurePipelineStage
---@param action "retry"|"cancel"
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_stage(context, pipeline, stage, action, on_done)
	local endpoint = builds_endpoint(context) .. "/" .. pipeline.id .. "/stages/" .. service.url_encode(stage.ref_name)
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
