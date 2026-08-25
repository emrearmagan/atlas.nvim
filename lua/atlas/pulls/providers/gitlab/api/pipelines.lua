local M = {}

local json = require("atlas.core.json")
local pipeline_utils = require("atlas.pulls.pipelines")
local service = require("atlas.providers.gitlab.client")

local PIPELINE_STATES = {
	SUCCESS = "SUCCESSFUL",
	FAILED = "FAILED",
	CANCELED = "STOPPED",
	SKIPPED = "STOPPED",
	MANUAL = "STOPPED",
	CREATED = "INPROGRESS",
	WAITING_FOR_RESOURCE = "INPROGRESS",
	PREPARING = "INPROGRESS",
	PENDING = "INPROGRESS",
	RUNNING = "INPROGRESS",
	SCHEDULED = "INPROGRESS",
	CANCELING = "INPROGRESS",
}

local PIPELINES_QUERY = [[
query($path:ID!,$iid:String!){
  project(fullPath:$path){
    mergeRequest(iid:$iid){
      head_pipeline:headPipeline{
        id
        status
        path
        totalJobs
        stages(first:100){
          nodes{
            name
            status
          }
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

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
	opts = opts or {}
	local path = pr.repo_full_name
	local iid = tonumber(pr.id)
	if path == "" or iid == nil then
		vim.schedule(function()
			on_done(nil, "Invalid MR identifier")
		end)
		return nil
	end

	local cache_key = string.format("gitlab_pulls:pipelines:%s!%d", path, iid)
	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.graphql(PIPELINES_QUERY, { path = path, iid = tostring(iid) }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local project = json.safe_table(result).project
		local merge_request = json.nilify(json.safe_table(project).mergeRequest)
		if merge_request == nil then
			on_done(nil, "Merge request not found")
			return
		end

		local pipelines = {}
		local item = json.nilify(merge_request.head_pipeline)
		if item then
			local id = (json.safe_str(item.id) or ""):match("/(%d+)$")
			local stages = {}
			for _, raw_stage in ipairs(json.safe_table(json.safe_table(item.stages).nodes)) do
				local stage = json.safe_table(raw_stage)
				table.insert(stages, {
					name = json.safe_str(stage.name) or "Stage",
					state = M.to_pipeline_state(stage.status),
					jobs = {},
				})
			end
			table.insert(pipelines, {
				name = string.format("Pipeline #%s", tostring(id or "")),
				state = M.to_pipeline_state(item.status),
				provider_state = json.safe_str(item.status) or "",
				url = web_url(item.path),
				id = tostring(id or ""),
				job_count = tonumber(json.nilify(item.totalJobs)),
				stages = stages,
			})
		end

		service.set_memory_cache(cache_key, pipelines)
		on_done(pipelines, nil)
	end, { action = "Fetch MR pipelines", project_path = path, iid = iid })
end

---@param pipeline PullsPipeline
---@param job_details { stage_name: string, job: PullsPipelineJob }[]
---@return PullsPipeline
local function with_job_details(pipeline, job_details)
	local detailed = {
		id = pipeline.id,
		name = pipeline.name,
		state = pipeline.state,
		provider_state = pipeline.provider_state,
		url = pipeline.url,
		job_count = pipeline.job_count,
		stages = {},
	}
	local stages_by_name = {}
	for _, stage in ipairs(pipeline.stages) do
		local copied_stage = {
			name = stage.name or "Stage",
			state = stage.state,
			jobs = {},
		}
		table.insert(detailed.stages, copied_stage)
		stages_by_name[copied_stage.name] = copied_stage
	end

	local synthesized_stages = {}
	for _, detail in ipairs(job_details) do
		local stage_name = detail.stage_name ~= "" and detail.stage_name or "Unknown stage"
		local stage = stages_by_name[stage_name]
		if stage == nil then
			stage = {
				name = stage_name,
				state = "UNKNOWN",
				jobs = {},
			}
			stages_by_name[stage_name] = stage
			table.insert(detailed.stages, stage)
			synthesized_stages[stage] = true
		end
		local job = detail.job
		table.insert(stage.jobs, {
			id = job.id,
			name = job.name,
			state = job.state,
			provider_state = job.provider_state,
			url = job.url,
			started_at = job.started_at,
			duration = job.duration,
		})
	end

	for stage in pairs(synthesized_stages) do
		stage.state = pipeline_utils.aggregate_state(stage.jobs)
	end
	return detailed
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(pipeline: PullsPipeline|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_details(pr, pipeline, _opts, on_done)
	local path = tostring(pr.repo_full_name or "")
	local pipeline_id = tonumber(pipeline.id)
	if path == "" or pipeline_id == nil then
		on_done(nil, path == "" and "Missing project" or "Missing pipeline ID")
		return nil
	end

	local endpoint = string.format("/projects/%s/pipelines/%d/jobs?per_page=100", service.url_encode(path), pipeline_id)
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local job_details = {}
		for _, raw_job_value in ipairs(json.safe_table(result)) do
			local raw_job = json.safe_table(raw_job_value)
			table.insert(job_details, {
				stage_name = json.safe_str(raw_job.stage) or "Unknown stage",
				job = {
					id = json.safe_str(raw_job.id) or "",
					name = json.safe_str(raw_job.name) or "Job",
					state = M.to_pipeline_state(raw_job.status),
					provider_state = json.safe_str(raw_job.status) or "",
					url = web_url(raw_job.web_url),
					started_at = json.safe_str(raw_job.started_at),
					duration = tonumber(json.nilify(raw_job.duration)),
				},
			})
		end

		on_done(with_job_details(pipeline, job_details), nil)
	end, { action = "Fetch pipeline details", project = path, pipeline_id = pipeline_id })
end

---@param pr PullRequest
---@param _pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(log: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_job_log(pr, _pipeline, job, on_done)
	local path = tostring(pr.repo_full_name or "")
	local job_id = tonumber(job.id)
	if path == "" or job_id == nil then
		vim.schedule(function()
			on_done(nil, path == "" and "Missing project" or "Missing pipeline job ID")
		end)
		return nil
	end

	local endpoint = string.format("/projects/%s/jobs/%d/trace", service.url_encode(path), job_id)
	return service.request_text("GET", endpoint, on_done, {
		action = "Fetch pipeline job log",
		project = path,
		job_id = job_id,
	})
end

---@param pr PullRequest
---@param endpoint string
---@param action string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function post_action(pr, endpoint, action, on_done)
	local path = tostring(pr.repo_full_name or "")
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

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.retry(pr, pipeline, on_done)
	local id = tonumber(pipeline.id)
	if not id then
		on_done(false, "Missing pipeline ID")
		return nil
	end
	return post_action(pr, string.format("pipelines/%d/retry", id), "Retry pipeline", on_done)
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.cancel(pr, pipeline, on_done)
	local id = tonumber(pipeline.id)
	if not id then
		on_done(false, "Missing pipeline ID")
		return nil
	end
	return post_action(pr, string.format("pipelines/%d/cancel", id), "Cancel pipeline", on_done)
end

---@param pr PullRequest
---@param job PullsPipelineJob
---@param action "retry"|"cancel"
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function run_job_action(pr, job, action, on_done)
	local id = tonumber(job.id)
	if not id then
		on_done(false, "Missing pipeline job ID")
		return nil
	end
	local label = action == "retry" and "Retry pipeline job" or "Cancel pipeline job"
	return post_action(pr, string.format("jobs/%d/%s", id, action), label, on_done)
end

---@param pr PullRequest
---@param job PullsPipelineJob
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.retry_job(pr, job, on_done)
	return run_job_action(pr, job, "retry", on_done)
end

---@param pr PullRequest
---@param job PullsPipelineJob
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.cancel_job(pr, job, on_done)
	return run_job_action(pr, job, "cancel", on_done)
end

return M
