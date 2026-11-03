local api = require("atlas.pulls.providers.forge.gitea.api")
local service = require("atlas.providers.forge.gitea.api")
local pipeline_utils = require("atlas.pulls.pipelines.utils")
local pullrequests = api.pullrequests
local request_scope = require("atlas.core.requests")

local M = {}

---@param slug string|nil
---@param value string|nil
---@return string|nil run_id, string|nil run_url, string|nil job_id
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
	local run_id, tail = url:sub(#prefix + 1):match("^(%d+)(.*)$")
	local job_id = tail and tail:match("^/jobs/(%d+)/?$")
	if not run_id or (tail ~= "" and tail ~= "/" and not job_id) then
		return nil, nil
	end
	return run_id, prefix .. run_id, job_id
end

---@param value string|nil
---@param conclusion string|nil
---@return PullsPipelineState
function M.state(value, conclusion)
	local state = (conclusion or ""):lower()
	if state == "" then
		state = (value or ""):lower()
	end
	if state == "success" then
		return "SUCCESSFUL"
	elseif state == "failure" or state == "error" then
		return "FAILED"
	elseif
		state == "pending"
		or state == "queued"
		or state == "in_progress"
		or state == "waiting"
		or state == "running"
		or state == "blocked"
		or state == "cancelling"
	then
		return "INPROGRESS"
	elseif state == "cancelled" or state == "canceled" then
		return "CANCELED"
	elseif state == "skipped" then
		return "SKIPPED"
	elseif state == "warning" then
		return "STOPPED"
	end
	return "UNKNOWN"
end

---@param raw table
---@param index integer
---@return PullsPipeline
local function external_pipeline(raw, index)
	local context = raw.context or ""
	local id = tostring(raw.id or "")
	local name = context ~= "" and context or (raw.description or "")
	return {
		id = "status:" .. (id ~= "" and id or (context ~= "" and context or tostring(index))),
		name = name ~= "" and name or "Commit status",
		state = M.state(raw.status),
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
		local run_id, run_url, job_id = M.actions_run(slug, target_url)
		if not run_id then
			table.insert(pipelines, external_pipeline(raw, index))
		else
			local context = raw.context or ""
			local workflow, job_name = context:match("^(.-)%s+/%s+(.+)$")
			local pipeline = actions_runs[run_id]
			if not pipeline then
				pipeline = {
					id = run_id,
					name = workflow or ("Actions run #" .. run_id),
					state = "UNKNOWN",
					url = run_url,
					stages = {
						{
							name = nil,
							state = "UNKNOWN",
							jobs = {},
						},
					},
				}
				actions_runs[run_id] = pipeline
				table.insert(pipelines, pipeline)
			end

			table.insert(pipeline.stages[1].jobs, {
				id = job_id or string.format("summary:%s:%s:%d", run_id, tostring(raw.id or context), index),
				name = job_name or (context ~= "" and context or "Job"),
				state = M.state(raw.status),
				url = target_url,
			})
		end
	end

	for _, pipeline in ipairs(pipelines) do
		local stage = pipeline.stages[1]
		if stage and #stage.jobs > 0 then
			stage.state = pipeline_utils.aggregate_state(stage.jobs)
			pipeline.state = stage.state
		end
	end
	return pipelines
end

---@param context PullsPipelineContext
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(context, opts, on_done)
	opts = opts or {}
	local target = context.target
	local pr = type(target) == "table" and target.source and target or nil
	local branch = type(target) == "string" and target or nil
	local owner, repo = context.repo_full_name:match("^([^/]+)/([^/]+)$")
	if not owner or (not pr and (not branch or branch == "")) then
		on_done(nil, "Invalid Gitea repository or pipeline target")
		return nil
	end
	local requests = request_scope.new()
	local function fetch_statuses(sha)
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
			local tasks = {}
			for index, item in ipairs(M.map(statuses, sha, context.repo_full_name)) do
				tasks[index] = function(done)
					return M.fetch_pipeline(context, item, function(detailed, detail_err)
						-- Status links remain useful when Actions details are inaccessible.
						-- Browser job indexes must never be used as API job IDs.
						if detail_err then
							done(vim.tbl_extend("force", {}, item, { stages = {} }), nil)
						else
							done(detailed, nil)
						end
					end)
				end
			end
			requests.all(tasks, function(items)
				on_done(items, nil)
			end)
		end)
	end

	if branch then
		fetch_statuses(branch)
	elseif tostring(pr.source.commit_hash or "") ~= "" then
		fetch_statuses(pr.source.commit_hash)
	else
		-- Global search omits the source SHA, so load the selected PR first.
		requests.run(function(done)
			return pullrequests.fetch_by_refs({ pr }, { force_refresh = opts.force_refresh }, done)
		end, function(pulls, err)
			local selected = pulls and pulls[1]
			local sha = selected and selected.source.commit_hash or ""
			if err or sha == "" then
				on_done(nil, err or "Unable to load Gitea pull request revisions")
				return
			end
			fetch_statuses(sha)
		end)
	end
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

---@param context PullsPipelineContext
---@return string|nil
local function repo_endpoint(context)
	local owner, repo = context.repo_full_name:match("^([^/]+)/([^/]+)$")
	if not owner then
		return nil
	end
	return string.format("/repos/%s/%s", service.url_encode(owner), service.url_encode(repo))
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@return integer|nil
function M.parse_run_id(context, pipeline)
	local id = tonumber(pipeline.id)
	if id ~= nil then
		return id
	end
	local run_id = M.actions_run(context.repo_full_name, pipeline.url)
	return tonumber(run_id)
end

---@param value string|nil
---@return string|nil
local function timestamp(value)
	local result = value
	if
		result == nil
		or result == ""
		or result:match("^0001%-01%-01T00:00:00")
		or result:match("^1970%-01%-01T00:00:00")
	then
		return nil
	end
	return result
end

---@param raw { jobs: table[] }
---@return PullsPipelineJob[]
local function map_jobs(raw)
	local jobs = {}
	for _, value in ipairs(raw.jobs or {}) do
		local started_at = timestamp(value.started_at)
		local completed_at = timestamp(value.completed_at)
		table.insert(jobs, {
			id = tostring(value.id or ""),
			name = tostring(value.name or "Job"),
			state = M.state(value.status, value.conclusion),
			url = service.absolute_url(value.html_url),
			started_at = started_at,
			duration = pipeline_utils.duration(started_at, completed_at),
		})
	end
	return jobs
end

---@param base string
---@param run_id integer
---@param on_done fun(raw: table|nil, err: string|nil)
---@return { cancel: fun() }
local function fetch_jobs(base, run_id, on_done)
	local page, jobs = 1, {}
	local requests = request_scope.new()

	local fetch_page
	function fetch_page()
		local endpoint = string.format("%s/actions/runs/%d/jobs", base, run_id)
			.. service.query({ limit = 50, page = page })
		requests.run(function(done)
			return service.request("GET", endpoint, nil, done)
		end, function(raw, err)
			if err then
				on_done(nil, err)
				return
			end
			local values = type(raw) == "table" and type(raw.jobs) == "table" and raw.jobs or {}
			local total = type(raw) == "table" and tonumber(raw.total_count) or nil
			vim.list_extend(jobs, values)
			if (total ~= nil and #jobs >= total) or #values == 0 then
				on_done({ total_count = total, jobs = jobs }, nil)
				return
			end
			page = page + 1
			fetch_page()
		end)
	end

	fetch_page()
	return requests
end

---@param event string|nil
---@return string|nil
local function trigger(event)
	return event and event ~= "" and (event:gsub("_", " ")) or nil
end

---@param run table Actions run from the API.
---@return PullsPipeline
local function map_run(run)
	local started_at = timestamp(run.started_at)
	local workflow = tostring(run.path or ""):match("^([^@]+)")
	return {
		id = tostring(run.id),
		name = workflow or ("Actions run #" .. tostring(run.run_number or run.id)),
		state = M.state(run.status, run.conclusion),
		url = service.absolute_url(run.html_url),
		number = tonumber(run.run_number),
		commit = run.head_sha,
		title = run.display_title,
		branch = run.head_branch,
		trigger = trigger(run.event),
		started_at = started_at,
		duration = pipeline_utils.duration(started_at, timestamp(run.completed_at)),
		stages = {},
	}
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(pipeline: PullsPipeline|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pipeline(context, pipeline, on_done)
	local run_id = M.parse_run_id(context, pipeline)
	if run_id == nil then
		on_done(pipeline, nil)
		return nil
	end
	local base = repo_endpoint(context)
	if base == nil then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end

	local requests = request_scope.new()
	requests.run(function(done)
		return service.request("GET", string.format("%s/actions/runs/%d", base, run_id), nil, done)
	end, function(run, err)
		if err then
			on_done(nil, err)
			return
		end
		requests.run(function(done)
			return fetch_jobs(base, run_id, done)
		end, function(raw, jobs_err)
			if jobs_err then
				on_done(nil, jobs_err)
				return
			end
			local jobs = map_jobs(raw)
			local mapped = map_run(run)
			local result = vim.tbl_extend("force", {}, pipeline, mapped, {
				name = pipeline.name,
				url = pipeline.url or mapped.url,
				stages = {
					{
						name = nil,
						state = #jobs > 0 and pipeline_utils.aggregate_state(jobs) or mapped.state,
						jobs = jobs,
					},
				},
			})
			on_done(result, nil)
		end)
	end)

	return requests
end

---@param context PullsPipelineContext
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_history(context, on_done)
	local base = repo_endpoint(context)
	local target = context.target
	local branch = type(target) == "string" and target or (target.source and target.source.branch) or target.branch
	if base == nil or not branch or branch == "" then
		on_done(nil, "Gitea build history needs a branch")
		return nil
	end
	local endpoint = base .. "/actions/runs" .. service.query({ branch = branch, limit = 30 })
	return service.request("GET", endpoint, nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local runs = {}
		for _, run in ipairs(type(raw) == "table" and raw.workflow_runs or {}) do
			table.insert(runs, map_run(run))
		end
		on_done(runs, nil)
	end, { action = "Fetch workflow history", repo = context.repo_full_name })
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(log: PullsLog|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_job_log(context, pipeline, job, on_done)
	local base = repo_endpoint(context)
	local job_id = tonumber(job.id)
	if base == nil or M.parse_run_id(context, pipeline) == nil or job_id == nil then
		on_done(nil, "Invalid Gitea Actions job")
		return nil
	end
	return service.request_text("GET", string.format("%s/actions/jobs/%d/logs", base, job_id), function(raw, err)
		on_done(raw and { raw = raw } or nil, err)
	end)
end

---@param context PullsPipelineContext
---@param endpoint string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function post_action(context, endpoint, on_done)
	local base = repo_endpoint(context)
	if base == nil then
		on_done(false, "Invalid Gitea repository")
		return nil
	end
	return service.request("POST", base .. endpoint, nil, function(_, err)
		on_done(err == nil, err)
	end)
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param failed_only boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.rerun(context, pipeline, failed_only, on_done)
	local run_id = M.parse_run_id(context, pipeline)
	if run_id == nil then
		on_done(false, "Invalid Gitea Actions run")
		return nil
	end
	local action = failed_only and "rerun-failed-jobs" or "rerun"
	return post_action(context, string.format("/actions/runs/%d/%s", run_id, action), on_done)
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.rerun_job(context, pipeline, job, on_done)
	local run_id = M.parse_run_id(context, pipeline)
	local job_id = tonumber(job.id)
	if run_id == nil or job_id == nil then
		on_done(false, "Invalid Gitea Actions job")
		return nil
	end
	return post_action(context, string.format("/actions/runs/%d/jobs/%d/rerun", run_id, job_id), on_done)
end

return M
