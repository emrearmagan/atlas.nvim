local json = require("atlas.core.json")
local pipeline_utils = require("atlas.pulls.pipelines.utils")
local requests = require("atlas.core.requests")
local service = require("atlas.providers.gitlab.client")

local M = {}

local PIPELINE_STATES = {
	SUCCESS = "SUCCESSFUL",
	FAILED = "FAILED",
	CANCELED = "CANCELED",
	SKIPPED = "SKIPPED",
	MANUAL = "MANUAL",
	CREATED = "PENDING",
	WAITING_FOR_RESOURCE = "QUEUED",
	PREPARING = "INPROGRESS",
	PENDING = "PENDING",
	RUNNING = "INPROGRESS",
	SCHEDULED = "PENDING",
	CANCELING = "INPROGRESS",
}

local MERGE_REQUEST_QUERY = [[
query($path:ID!,$iid:String!){
  project(fullPath:$path){
    mergeRequest(iid:$iid){
      headPipeline {
        id iid name status source path sha ref startedAt createdAt duration
        commit { title }
        project { fullPath ciConfigPathOrDefault }
        stages(first:100) { nodes { name status } }
        jobs(first:100,retried:false) {
          nodes {
            id name kind status webPath startedAt duration stage { name status }
            downstreamPipeline { id iid project { fullPath } }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
}
]]

local BRANCH_QUERY = [[
query($path:ID!,$ref:String!){
  project(fullPath:$path){
    pipelines(ref:$ref,first:1) {
      nodes {
        id iid name status source path sha ref startedAt createdAt duration
        commit { title }
        project { fullPath ciConfigPathOrDefault }
        stages(first:100) { nodes { name status } }
        jobs(first:100,retried:false) {
          nodes {
            id name kind status webPath startedAt duration stage { name status }
            downstreamPipeline { id iid project { fullPath } }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
}
]]

local PIPELINE_QUERY = [[
query($path:ID!,$iid:ID!){
  project(fullPath:$path){
    pipeline(iid:$iid) {
      id iid name status source path sha ref startedAt createdAt duration
      commit { title }
      project { fullPath ciConfigPathOrDefault }
      stages(first:100) { nodes { name status } }
      jobs(first:100,retried:false) {
        nodes {
          id name kind status webPath startedAt duration stage { name status }
          downstreamPipeline { id iid project { fullPath } }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
]]

local JOBS_QUERY = [[
query($path:ID!,$iid:ID!,$cursor:String!){
  project(fullPath:$path){
    pipeline(iid:$iid) {
      jobs(first:100,after:$cursor,retried:false) {
        nodes {
          id name kind status webPath startedAt duration stage { name status }
          downstreamPipeline { id iid project { fullPath } }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
]]

local BRANCH_HISTORY_QUERY = [[
query($path:ID!,$ref:String!){
  project(fullPath:$path){
    pipelines(ref:$ref,first:30) {
      nodes {
        id iid name status source path sha ref startedAt createdAt duration
        commit { title }
        project { fullPath }
      }
    }
  }
}
]]

local MERGE_REQUEST_HISTORY_QUERY = [[
query($path:ID!,$iid:String!){
  project(fullPath:$path){
    mergeRequest(iid:$iid){
      pipelines(first:30) {
        nodes {
          id iid name status source path sha ref startedAt createdAt duration
          commit { title }
          project { fullPath }
        }
      }
    }
  }
}
]]

---@param status string|nil
---@return PullsPipelineState
function M.to_pipeline_state(status)
	return PIPELINE_STATES[tostring(status or ""):upper()] or "UNKNOWN"
end

---@param path any
---@return string|nil
local function web_url(path)
	local value = json.safe_str(path)
	if value == nil or value == "" then
		return nil
	end
	if value:match("^https?://") then
		return value
	end
	local origin = service.base_url():match("^(https?://[^/]+)") or service.base_url()
	return origin .. (value:sub(1, 1) == "/" and value or ("/" .. value))
end

---@param item table
---@return GitLabPipeline
local function parse_pipeline(item)
	local id = (json.safe_str(item.id) or ""):match("(%d+)$") or ""
	local project = json.safe_table(item.project)
	local source = json.safe_str(item.source)
	local config_path = json.safe_str(project.ciConfigPathOrDefault)
	if source == "parent_pipeline" then
		config_path = nil
	end
	return {
		id = id,
		iid = json.safe_str(item.iid),
		name = json.safe_str(item.name) or "Pipeline",
		number = tonumber(id),
		commit = json.safe_str(item.sha),
		title = json.safe_str(json.safe_table(item.commit).title),
		branch = json.safe_str(item.ref),
		trigger = source and (source:gsub("_event$", ""):gsub("_", " ")),
		started_at = json.safe_str(item.startedAt) or json.safe_str(item.createdAt),
		duration = tonumber(json.nilify(item.duration)),
		state = M.to_pipeline_state(item.status),
		status = json.safe_str(item.status) or "",
		project_path = json.safe_str(project.fullPath),
		config_path = config_path,
		url = web_url(item.path),
		stages = {},
	}
end

---@param item table
---@param raw_jobs table[]
---@return GitLabPipeline
local function parse_pipeline_with_jobs(item, raw_jobs)
	local pipeline = parse_pipeline(item)
	local stages_by_name = {}
	for _, raw_stage in ipairs(json.safe_table(json.safe_table(item.stages).nodes)) do
		local stage = {
			name = json.safe_str(raw_stage.name) or "Stage",
			state = M.to_pipeline_state(raw_stage.status),
			jobs = {},
		}
		table.insert(pipeline.stages, stage)
		stages_by_name[stage.name] = stage
	end

	for _, raw_job in ipairs(raw_jobs) do
		local downstream = json.nilify(raw_job.downstreamPipeline)
		if raw_job.kind ~= "BRIDGE" or downstream then
			local raw_stage = json.safe_table(raw_job.stage)
			local stage_name = json.safe_str(raw_stage.name) or "Unknown stage"
			local stage = stages_by_name[stage_name]
			if not stage then
				stage = { name = stage_name, state = M.to_pipeline_state(raw_stage.status), jobs = {} }
				stages_by_name[stage_name] = stage
				table.insert(pipeline.stages, stage)
			end
			table.insert(stage.jobs, {
				id = (json.safe_str(raw_job.id) or ""):match("(%d+)$") or "",
				name = json.safe_str(raw_job.name) or "Job",
				state = M.to_pipeline_state(raw_job.status),
				status = json.safe_str(raw_job.status) or "",
				project_path = pipeline.project_path,
				url = web_url(raw_job.webPath),
				started_at = json.safe_str(raw_job.startedAt),
				duration = tonumber(json.nilify(raw_job.duration)),
				downstream = downstream and parse_pipeline(downstream) or nil,
			})
		end
	end
	return pipeline
end

---@param connection table
---@param previous string|nil
---@return string|nil cursor, string|nil error
local function next_cursor(connection, previous)
	local page = json.safe_table(connection.pageInfo)
	if page.hasNextPage ~= true then
		return nil
	end
	local cursor = json.safe_str(page.endCursor)
	if not cursor or cursor == "" or cursor == previous then
		return nil, "GitLab pipeline pagination did not advance"
	end
	return cursor
end

---@param scope AtlasRequestScope
---@param path string|nil
---@param iid string|nil
---@param request_context table
---@param on_done fun(item: table|nil, err: string|nil)
local function query_pipeline(scope, path, iid, request_context, on_done)
	scope.run(function(done)
		return service.graphql(PIPELINE_QUERY, { path = path, iid = iid }, done, request_context)
	end, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local project = json.safe_table(result).project
		local item = json.nilify(json.safe_table(project).pipeline)
		if not item then
			on_done(nil, "Pipeline not found")
			return
		end
		on_done(item, nil)
	end)
end

---@param scope AtlasRequestScope
---@param item table
---@param request_context table
---@param on_done fun(pipeline: GitLabPipeline|nil, err: string|nil)
local function load_pipeline(scope, item, request_context, on_done)
	local jobs = {}

	---@param job PullsPipelineJob
	---@param done fun(pipeline: GitLabPipeline|nil, err: string|nil)
	local function load_child(job, done)
		local downstream = job.downstream
		---@cast downstream GitLabPipeline
		query_pipeline(scope, downstream.project_path, downstream.iid, request_context, function(child, err)
			if not child then
				done(nil, err)
				return
			end
			load_pipeline(scope, child, request_context, function(loaded, load_err)
				job.downstream = loaded
				done(loaded, load_err)
			end)
		end)
	end

	local function load_downstream()
		local pipeline = parse_pipeline_with_jobs(item, jobs)
		local starts = {}
		for _, stage in ipairs(pipeline.stages) do
			for _, job in ipairs(stage.jobs) do
				if job.downstream then
					starts[job.downstream.id] = function(done)
						load_child(job, done)
					end
				end
			end
		end
		scope.all(starts, function(_, errors)
			local _, err = next(errors)
			if err then
				on_done(nil, err)
			else
				on_done(pipeline, nil)
			end
		end)
	end

	local function fetch_page(connection, cursor)
		connection = json.safe_table(connection)
		vim.list_extend(jobs, json.safe_table(connection.nodes))
		local next_page, cursor_err = next_cursor(connection, cursor)
		if cursor_err then
			on_done(nil, cursor_err)
			return
		end
		if not next_page then
			load_downstream()
			return
		end

		local variables = {
			path = json.safe_table(item.project).fullPath,
			iid = json.safe_str(item.iid),
			cursor = next_page,
		}
		scope.run(function(done)
			return service.graphql(JOBS_QUERY, variables, done, request_context)
		end, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			local project = json.safe_table(result).project
			local pipeline = json.nilify(json.safe_table(project).pipeline)
			if not pipeline then
				on_done(nil, "Pipeline not found while loading jobs")
				return
			end
			fetch_page(pipeline.jobs, next_page)
		end)
	end

	fetch_page(item.jobs)
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(pipeline: PullsPipeline|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pipeline(context, pipeline, on_done)
	---@cast pipeline GitLabPipeline
	local path = pipeline.project_path or context.repo_full_name
	local id = tonumber(pipeline.id)
	if not path or path == "" then
		on_done(nil, "Pipeline project not found")
		return nil
	end
	if not pipeline.iid and id == nil then
		on_done(nil, "Missing pipeline ID")
		return nil
	end

	local scope = requests.new()
	local request_context = { action = "Fetch pipeline", project_path = path, pipeline_id = pipeline.id }

	local function load(iid)
		query_pipeline(scope, path, iid, request_context, function(item, err)
			if not item then
				on_done(nil, err)
				return
			end
			load_pipeline(scope, item, request_context, on_done)
		end)
	end

	if pipeline.iid then
		load(pipeline.iid)
	else
		scope.run(function(done)
			local endpoint = string.format("/projects/%s/pipelines/%d", service.url_encode(path), id)
			return service.request("GET", endpoint, nil, done, request_context)
		end, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			load(json.safe_str(json.safe_table(result).iid))
		end)
	end
	return { cancel = scope.cancel }
end

---@param context PullsPipelineContext
---@param opts { force_refresh?: boolean|nil }|nil
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(context, opts, on_done)
	local target = context.target
	local pr = type(target) == "table" and target or nil
	---@cast pr PullRequest|nil
	local path = tostring(context.repo_full_name or "")
	local iid = pr and tonumber(pr.id)
	local branch = type(target) == "string" and target or nil
	if path == "" or (pr and not iid) or (not pr and (not branch or branch == "")) then
		vim.schedule(function()
			on_done(nil, pr and "Invalid MR identifier" or "Missing pipeline repository or branch")
		end)
		return nil
	end

	local cache_key = pr and string.format("gitlab_pulls:pipelines:%s!%d", path, iid)
		or string.format("gitlab_pulls:branch_pipelines:%s:%s", path, branch)
	if not (opts or {}).force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local scope = requests.new()
	local request_context = { action = "Fetch pipelines", project_path = path, iid = iid, branch = branch }

	local function finish(pipeline, err)
		scope.cancel()
		if err then
			on_done(nil, err)
			return
		end
		local pipelines = pipeline and { pipeline } or {}
		service.set_memory_cache(cache_key, pipelines)
		on_done(pipelines, nil)
	end

	scope.run(function(done)
		if pr then
			return service.graphql(MERGE_REQUEST_QUERY, { path = path, iid = tostring(iid) }, done, request_context)
		end
		return service.graphql(BRANCH_QUERY, { path = path, ref = branch }, done, request_context)
	end, function(result, err)
		if err then
			finish(nil, err)
			return
		end
		local project = json.safe_table(json.safe_table(result).project)
		local item
		if pr then
			local mr = json.nilify(project.mergeRequest)
			if not mr then
				finish(nil, "Merge request not found")
				return
			end
			item = json.nilify(mr.headPipeline)
		else
			item = json.safe_table(json.safe_table(project.pipelines).nodes)[1]
		end
		if item then
			load_pipeline(scope, item, request_context, finish)
		else
			finish()
		end
	end)
	return { cancel = scope.cancel }
end

---@param context PullsPipelineContext
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_history(context, on_done)
	local target = context.target
	local is_branch = type(target) == "string"
	local pr = not is_branch and target.source and target or nil
	local pipeline = not is_branch and not pr and target or nil
	---@cast pipeline GitLabPipeline|nil
	local path = (pipeline and pipeline.project_path) or context.repo_full_name
	local branch = is_branch and target or (pipeline and pipeline.branch)
	local scope = requests.new()
	local request_context = { action = "Fetch pipeline history", project_path = path }

	local function fetch_runs(ref)
		scope.run(function(done)
			if pr then
				local variables = { path = path, iid = tostring(pr.id) }
				return service.graphql(MERGE_REQUEST_HISTORY_QUERY, variables, done, request_context)
			end
			return service.graphql(BRANCH_HISTORY_QUERY, { path = path, ref = ref }, done, request_context)
		end, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			local project = json.safe_table(json.safe_table(result).project)
			local connection = pr and json.safe_table(project.mergeRequest).pipelines or project.pipelines
			local pipelines = {}
			for _, item in ipairs(json.safe_table(json.safe_table(connection).nodes)) do
				table.insert(pipelines, parse_pipeline(item))
			end
			on_done(pipelines, nil)
		end)
	end

	if pipeline and not branch then
		scope.run(function(done)
			local endpoint = string.format("/projects/%s/pipelines/%s", service.url_encode(path), pipeline.id)
			return service.request("GET", endpoint, nil, done, request_context)
		end, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			fetch_runs(result.ref)
		end)
	else
		fetch_runs(branch)
	end
	return scope
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(file: { path: string, content: string }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_config(context, pipeline, on_done)
	---@cast pipeline GitLabPipeline
	local path = pipeline.config_path
	local project = pipeline.project_path or context.repo_full_name
	local ref = pipeline.commit
	if not path then
		on_done(nil, "No configuration file for this pipeline")
		return nil
	end
	if not ref or ref == "" then
		on_done(nil, "Missing pipeline commit")
		return nil
	end
	if path:match("^https?://") or path:find("@", 1, true) then
		on_done(nil, "Configuration files outside this GitLab project are not supported")
		return nil
	end

	local endpoint = string.format(
		"/projects/%s/repository/files/%s/raw?ref=%s",
		service.url_encode(project),
		service.url_encode(path),
		service.url_encode(ref)
	)
	return service.request_text("GET", endpoint, function(content, err)
		on_done(content and { path = path, content = content } or nil, err)
	end, { action = "Fetch pipeline configuration", project = project, pipeline_id = pipeline.id })
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(job: PullsPipelineJob|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_job(context, pipeline, job, on_done)
	---@cast job GitLabPipelineJob
	---@cast pipeline GitLabPipeline
	local path = job.project_path or pipeline.project_path or context.repo_full_name
	local job_id = tonumber(job.id)
	if path == "" or job_id == nil then
		on_done(nil, path == "" and "Missing project" or "Missing pipeline job ID")
		return nil
	end

	local endpoint = string.format("/projects/%s/jobs/%d", service.url_encode(path), job_id)
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		---@type GitLabPipelineJob
		local fresh_job = {
			id = tostring(result.id),
			name = result.name,
			state = M.to_pipeline_state(result.status),
			status = result.status,
			project_path = path,
			url = web_url(result.web_url),
			started_at = json.safe_str(result.started_at),
			duration = tonumber(json.nilify(result.duration)),
		}
		on_done(fresh_job, nil)
	end, { action = "Fetch pipeline job", project = path, job_id = job_id })
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(log: PullsLog|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_job_log(context, pipeline, job, on_done)
	---@cast job GitLabPipelineJob
	---@cast pipeline GitLabPipeline
	local path = job.project_path or pipeline.project_path or context.repo_full_name
	local job_id = tonumber(job.id)
	if path == "" or job_id == nil then
		vim.schedule(function()
			on_done(nil, path == "" and "Missing project" or "Missing pipeline job ID")
		end)
		return nil
	end

	local endpoint = string.format("/projects/%s/jobs/%d/trace", service.url_encode(path), job_id)
	return service.request_text("GET", endpoint, function(raw, err)
		on_done(raw and { raw = raw } or nil, err)
	end, {
		action = "Fetch pipeline job log",
		project = path,
		job_id = job_id,
	})
end

---@param commit PullsCommit
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(status: string|nil, url: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commit_status(commit, opts, on_done)
	local path = commit.repo_full_name
	if not path or path == "" then
		on_done(nil, nil, "Missing project")
		return nil
	end
	local cache_key = string.format("gitlab_pulls:commit_status:%s:%s", path, commit.hash)
	if not (opts or {}).force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached.status, cached.url, nil)
			return nil
		end
	end

	local endpoint = string.format("/projects/%s/repository/commits/%s/statuses", service.url_encode(path), commit.hash)
	return service.fetch_all_pages(endpoint, function(result, err)
		if err then
			on_done(nil, nil, err)
			return
		end
		---@cast result table[]
		local statuses, url = {}, nil
		for _, item in ipairs(result) do
			table.insert(statuses, { state = M.to_pipeline_state(item.status) })
			url = url or web_url(item.target_url)
		end
		local status = pipeline_utils.aggregate_state(statuses):lower()
		service.set_memory_cache(cache_key, { status = status, url = url })
		on_done(status, url, nil)
	end, { action = "Fetch commit status", project = path, commit_hash = commit.hash })
end

---@param path string
---@param endpoint string
---@param action string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function post_action(path, endpoint, action, on_done)
	if path == "" then
		on_done(false, "Missing project")
		return nil
	end
	return service.request(
		"POST",
		string.format("/projects/%s/%s", service.url_encode(path), endpoint),
		nil,
		function(_, err)
			on_done(err == nil, err)
		end,
		{ action = action, project = path }
	)
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.retry(context, pipeline, on_done)
	---@cast pipeline GitLabPipeline
	local id = tonumber(pipeline.id)
	if not id then
		on_done(false, "Missing pipeline ID")
		return nil
	end
	return post_action(
		pipeline.project_path or context.repo_full_name,
		string.format("pipelines/%d/retry", id),
		"Retry pipeline",
		on_done
	)
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.cancel(context, pipeline, on_done)
	---@cast pipeline GitLabPipeline
	local id = tonumber(pipeline.id)
	if not id then
		on_done(false, "Missing pipeline ID")
		return nil
	end
	return post_action(
		pipeline.project_path or context.repo_full_name,
		string.format("pipelines/%d/cancel", id),
		"Cancel pipeline",
		on_done
	)
end

---@param context PullsPipelineContext
---@param job PullsPipelineJob
---@param action "retry"|"cancel"
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function run_job_action(context, job, action, on_done)
	---@cast job GitLabPipelineJob
	local id = tonumber(job.id)
	if not id then
		on_done(false, "Missing pipeline job ID")
		return nil
	end
	local label = action == "retry" and "Retry pipeline job" or "Cancel pipeline job"
	return post_action(
		job.project_path or context.repo_full_name,
		string.format("jobs/%d/%s", id, action),
		label,
		on_done
	)
end

---@param context PullsPipelineContext
---@param job PullsPipelineJob
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.retry_job(context, job, on_done)
	return run_job_action(context, job, "retry", on_done)
end

---@param context PullsPipelineContext
---@param job PullsPipelineJob
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.cancel_job(context, job, on_done)
	return run_job_action(context, job, "cancel", on_done)
end

return M
