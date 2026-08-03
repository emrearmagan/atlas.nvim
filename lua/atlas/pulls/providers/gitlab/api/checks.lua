local M = {}

local providers = require("atlas.pulls.providers")
local service = require("atlas.pulls.providers.gitlab.api.service")
local mr_api = require("atlas.pulls.providers.gitlab.api.mergerequests")

---@param pr PullRequest
---@return string project_path, integer|nil iid
local function project_iid(pr)
	return pr.repo_full_name, tonumber(pr.id)
end

---@param status string|nil
---@return "SUCCESSFUL"|"FAILED"|"INPROGRESS"|"STOPPED"
local function map_pipeline_state(status)
	local s = tostring(status or ""):lower()
	if s == "success" then
		return "SUCCESSFUL"
	elseif s == "failed" then
		return "FAILED"
	elseif s == "canceled" or s == "skipped" then
		return "STOPPED"
	end
	return "INPROGRESS"
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_pipelines(pr, opts, on_done)
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
		for _, item in ipairs(type(result) == "table" and result or {}) do
			if type(item) == "table" then
				local id = item.id
				table.insert(pipelines, {
					name = string.format("Pipeline #%s", tostring(id or "")),
					state = map_pipeline_state(item.status),
					provider_state = tostring(item.status or ""),
					url = type(item.web_url) == "string" and item.web_url or nil,
					key = id and tostring(id) or nil,
					provider_id = id and tostring(id) or nil,
					commit_hash = tostring(item.sha or ""),
					jobs = {},
				})
			end
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
			if pipeline_id == nil then
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
						for _, job in ipairs(type(jobs) == "table" and jobs or {}) do
							if type(job) == "table" then
								table.insert(pipeline.jobs, {
									id = job.id or "",
									name = tostring(job.name or "Job"),
									state = map_pipeline_state(job.status),
									provider_state = tostring(job.status or ""),
									url = type(job.web_url) == "string" and job.web_url or nil,
									stage = type(job.stage) == "string" and job.stage or nil,
									started_at = job.started_at,
									completed_at = job.finished_at,
									duration = tonumber(job.duration),
								})
							end
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
				if type(handle.cancel) == "function" then
					handle.cancel()
				end
			end
		end,
	}
end

---@param pr PullRequest
---@param _pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(log: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_pipeline_job_log(pr, _pipeline, job, on_done)
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
local function post_pipeline_action(pr, endpoint, action, on_done)
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
function M.retry_pipeline(pr, pipeline, on_done)
	local pipeline_id = tonumber(pipeline.provider_id)
	if not pipeline_id then
		on_done(false, "Missing pipeline ID")
		return nil
	end
	return post_pipeline_action(pr, string.format("pipelines/%d/retry", pipeline_id), "Retry pipeline", on_done)
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.cancel_pipeline(pr, pipeline, on_done)
	local pipeline_id = tonumber(pipeline.provider_id)
	if not pipeline_id then
		on_done(false, "Missing pipeline ID")
		return nil
	end
	return post_pipeline_action(pr, string.format("pipelines/%d/cancel", pipeline_id), "Cancel pipeline", on_done)
end

---@param pr PullRequest
---@param job PullsPipelineJob
---@param action "retry"|"cancel"
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function run_job_action(pr, job, action, on_done)
	local job_id = tonumber(job.id)
	if not job_id then
		on_done(false, "Missing pipeline job ID")
		return nil
	end
	local label = action == "retry" and "Retry pipeline job" or "Cancel pipeline job"
	return post_pipeline_action(pr, string.format("jobs/%d/%s", job_id, action), label, on_done)
end

---@param pr PullRequest
---@param job PullsPipelineJob
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.retry_pipeline_job(pr, job, on_done)
	return run_job_action(pr, job, "retry", on_done)
end

---@param pr PullRequest
---@param job PullsPipelineJob
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.cancel_pipeline_job(pr, job, on_done)
	return run_job_action(pr, job, "cancel", on_done)
end

---@param raw table
---@return PullsMergeCheck[]
local function parse_merge_checks(raw)
	local checks = {}
	local dms = tostring(raw.detailed_merge_status or ""):lower()
	local has_conflicts = raw.has_conflicts == true

	if raw.draft == true or raw.work_in_progress == true then
		table.insert(checks, {
			key = "draft",
			state = "warning",
			label = "This merge request is still a draft",
			details = { "Draft merge requests cannot be merged." },
		})
	end

	if has_conflicts or dms == "conflict" then
		table.insert(checks, {
			key = "conflicts",
			state = "failed",
			label = "This branch has conflicts that must be resolved",
			details = { "Conflicting files must be resolved before merging." },
		})
	elseif dms == "mergeable" then
		table.insert(checks, {
			key = "conflicts",
			state = "successful",
			label = "No conflicts with target branch",
		})
	end

	if raw.blocking_discussions_resolved == false or dms == "discussions_not_resolved" then
		table.insert(checks, {
			key = "discussions",
			state = "failed",
			label = "Unresolved discussions",
			details = { "Resolve all threads before merging." },
		})
	end

	if dms == "merge_request_blocked" then
		table.insert(checks, {
			key = "blocks",
			state = "failed",
			label = "Merge request dependencies must be merged",
		})
	end

	if dms == "requested_changes" then
		table.insert(checks, {
			key = "requested_changes",
			state = "failed",
			label = "Change requests must be approved by the requesting user",
		})
	end

	if dms == "not_approved" then
		table.insert(checks, {
			key = "approvals",
			state = "failed",
			label = "All required approvals must be given",
		})
	end

	if dms == "need_rebase" then
		table.insert(checks, {
			key = "rebase",
			state = "failed",
			label = "Source branch must be rebased onto target",
		})
	end

	if dms == "jira_association_missing" then
		table.insert(checks, {
			key = "jira",
			state = "failed",
			label = "Jira issue must be referenced",
		})
	end

	if dms == "external_status_checks" then
		table.insert(checks, {
			key = "external_checks",
			state = "failed",
			label = "External status checks must pass",
		})
	end

	if dms == "broken_status" then
		table.insert(checks, {
			key = "broken",
			state = "failed",
			label = "Merge status is broken",
		})
	end

	if dms == "preparing" then
		table.insert(checks, {
			key = "preparing",
			state = "inprogress",
			label = "Preparing merge",
		})
	end

	if dms == "ci_must_pass" or dms == "ci_still_running" then
		table.insert(checks, {
			key = "ci",
			state = dms == "ci_still_running" and "inprogress" or "warning",
			label = "Pipeline must pass",
			details = { "CI is required to merge." },
		})
	end

	return checks
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(checks: PullsMergeCheck[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_merge_checks(pr, opts, on_done)
	opts = opts or {}
	local pending = 2
	local mr_raw, pipelines_result
	local first_err

	local function finish()
		pending = pending - 1
		if pending > 0 then
			return
		end
		if mr_raw == nil and pipelines_result == nil then
			on_done(nil, first_err or "Failed to fetch merge checks")
			return
		end
		local checks = parse_merge_checks(mr_raw or {})
		local bc = providers.pipelines_check(pipelines_result, "Pipelines")
		if bc then
			table.insert(checks, bc)
		end
		on_done(checks, nil)
	end

	local h_mr = mr_api.get_mr(pr, { force_refresh = opts.force_refresh == true }, function(fresh, err)
		if err then
			first_err = first_err or err
		elseif fresh then
			mr_raw = fresh._raw
		end
		finish()
	end)

	local h_pipelines = M.get_pipelines(pr, opts, function(result, err)
		if err then
			first_err = first_err or err
		else
			pipelines_result = result
		end
		finish()
	end)

	return {
		cancel = function()
			if h_mr and h_mr.cancel then
				h_mr.cancel()
			end
			if h_pipelines and h_pipelines.cancel then
				h_pipelines.cancel()
			end
		end,
	}
end

return M
