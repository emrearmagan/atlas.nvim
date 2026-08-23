local M = {}

local service = require("atlas.providers.gitlab.client")

---@param pr PullRequest
---@return string project_path, integer|nil iid
local function project_iid(pr)
	return pr.repo_full_name, tonumber(pr.id)
end

---@param status string|nil
---@return "SUCCESSFUL"|"FAILED"|"INPROGRESS"|"STOPPED"
local function map_state(status)
	local value = tostring(status or ""):lower()
	if value == "success" then
		return "SUCCESSFUL"
	elseif value == "failed" then
		return "FAILED"
	elseif value == "canceled" or value == "skipped" then
		return "STOPPED"
	end
	return "INPROGRESS"
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
	opts = opts or {}
	local path, iid = project_iid(pr)
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

	local cancelled = false
	local handles = {}
	local function track(handle)
		if handle then
			table.insert(handles, handle)
		end
	end

	local project = service.url_encode(path)
	local endpoint = string.format("/projects/%s/merge_requests/%d/pipelines?per_page=100", project, iid)
	track(service.request("GET", endpoint, nil, function(result, err)
		if cancelled then
			return
		end
		if err then
			on_done(nil, err)
			return
		end

		local pipelines = {}
		for _, item in ipairs(result) do
			local id = item.id
			table.insert(pipelines, {
				name = string.format("Pipeline #%s", tostring(id or "")),
				state = map_state(item.status),
				provider_state = tostring(item.status or ""),
				url = type(item.web_url) == "string" and item.web_url or nil,
				key = id and tostring(id) or nil,
				provider_id = id and tostring(id) or nil,
				commit_hash = tostring(item.sha or ""),
				jobs = {},
			})
		end

		if #pipelines == 0 then
			service.set_memory_cache(cache_key, pipelines)
			on_done(pipelines, nil)
			return
		end

		local pending = #pipelines
		local first_err
		local function finish()
			if cancelled then
				return
			end
			pending = pending - 1
			if pending > 0 then
				return
			end
			if first_err then
				on_done(nil, first_err)
				return
			end
			service.set_memory_cache(cache_key, pipelines)
			on_done(pipelines, nil)
		end

		for _, pipeline in ipairs(pipelines) do
			local pipeline_id = tonumber(pipeline.provider_id)
			if not pipeline_id then
				finish()
			else
				local jobs_endpoint = string.format("/projects/%s/pipelines/%d/jobs?per_page=100", project, pipeline_id)
				track(service.request("GET", jobs_endpoint, nil, function(jobs, jobs_err)
					if cancelled then
						return
					end
					if jobs_err then
						first_err = first_err or tostring(jobs_err)
					else
						for _, job in ipairs(jobs) do
							table.insert(pipeline.jobs, {
								id = job.id or "",
								name = tostring(job.name or "Job"),
								state = map_state(job.status),
								provider_state = tostring(job.status or ""),
								url = type(job.web_url) == "string" and job.web_url or nil,
								stage = type(job.stage) == "string" and job.stage or nil,
								started_at = job.started_at,
								completed_at = job.finished_at,
								duration = tonumber(job.duration),
							})
						end
					end
					finish()
				end))
			end
		end
	end))

	return {
		cancel = function()
			cancelled = true
			for _, handle in ipairs(handles) do
				handle.cancel()
			end
		end,
	}
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
	local id = tonumber(pipeline.provider_id)
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
	local id = tonumber(pipeline.provider_id)
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
