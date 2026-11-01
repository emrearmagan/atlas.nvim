local api = require("atlas.pulls.providers.forge.forgejo.api")
local service = require("atlas.providers.forge.forgejo.api")
local pipeline_utils = require("atlas.pulls.pipelines.utils")
local pullrequests = api.pullrequests
local request_scope = require("atlas.core.requests")

local M = {}

---@param slug string|nil
---@param value string|nil
---@return string|nil run_number, string|nil run_url, string|nil job_id
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
	local job_id = tail and tail:match("^/jobs/(%d+)/?$")
	if not run_number or (tail ~= "" and tail ~= "/" and not job_id) then
		return nil, nil
	end
	return run_number, prefix .. run_number, job_id
end

---@param value string|nil
---@return PullsPipelineState
function M.state(value)
	local state = tostring(value or ""):lower()
	if state == "success" then
		return "SUCCESSFUL"
	elseif state == "failure" or state == "error" then
		return "FAILED"
	elseif state == "pending" or state == "waiting" or state == "running" or state == "blocked" then
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
		local run_number, run_url, job_id = M.actions_run(slug, target_url)
		if not run_number then
			table.insert(pipelines, external_pipeline(raw, index))
		else
			local context = raw.context or ""
			local workflow, job_name = context:match("^(.-)%s+/%s+(.+)$")
			local pipeline = actions_runs[run_number]
			if not pipeline then
				pipeline = {
					id = run_number,
					name = workflow or ("Actions run #" .. run_number),
					state = "UNKNOWN",
					url = run_url,
					job_count = 0,
					stages = {
						{
							name = nil,
							state = "UNKNOWN",
							jobs = {},
						},
					},
				}
				actions_runs[run_number] = pipeline
				table.insert(pipelines, pipeline)
			end

			table.insert(pipeline.stages[1].jobs, {
				id = job_id or string.format("summary:%s:%s:%d", run_number, tostring(raw.id or context), index),
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
			pipeline.job_count = #stage.jobs
		end
	end
	return pipelines
end

local fetch_details

---@param context PullsPipelineContext
---@param opts { force_refresh?: boolean, pipeline?: PullsPipeline }|nil
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(context, opts, on_done)
	opts = opts or {}
	local target = context.target
	local pipeline = opts.pipeline or (type(target) == "table" and target.stages and target or nil)
	if pipeline then
		return fetch_details(context, pipeline, function(result, err)
			on_done(result and { result } or nil, err)
		end)
	end

	local pr = type(target) == "table" and target.source and target or nil
	local branch = type(target) == "string" and target or nil
	local owner, repo = context.repo_full_name:match("^([^/]+)/([^/]+)$")
	if not owner or (not pr and (not branch or branch == "")) then
		on_done(nil, "Invalid Forgejo repository or pipeline target")
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
					return fetch_details(context, item, function(detailed, detail_err)
						-- Status links remain useful when Actions details are inaccessible.
						-- Browser job indexes must never be used as API job IDs.
						if detail_err then
							done(vim.tbl_extend("force", {}, item, { stages = {}, job_count = 0 }), nil)
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
				on_done(nil, err or "Unable to load Forgejo pull request revisions")
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
---@return string|nil
function M.parse_run_number(context, pipeline)
	return M.actions_run(context.repo_full_name, pipeline.url)
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(run: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function resolve_run(context, pipeline, on_done)
	local base = repo_endpoint(context)
	local run_number = M.parse_run_number(context, pipeline)
	if not base or not run_number then
		on_done(nil, "Invalid Forgejo Actions run")
		return nil
	end
	local target = context.target
	local sha = type(target) == "table" and target.source and tostring(target.source.commit_hash or "") or ""
	return service.request("GET", base .. "/actions/runs" .. service.query({
		run_number = run_number,
		head_sha = sha ~= "" and sha or nil,
		limit = 1,
	}), nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local runs = type(raw.workflow_runs) == "table" and raw.workflow_runs or {}
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

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(pipeline: PullsPipeline|nil, err: string|nil)
---@return { cancel: fun() }|nil
function fetch_details(context, pipeline, on_done)
	local base = repo_endpoint(context)
	if not base or not M.parse_run_number(context, pipeline) then
		on_done(pipeline, nil)
		return nil
	end
	local requests = request_scope.new()
	requests.run(function(done)
		return resolve_run(context, pipeline, done)
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
			for index, job in ipairs(raw) do
				local job_id = tostring(job.id or "")
				table.insert(jobs, {
					id = job_id ~= "" and job_id or string.format("job:%s:%d", run_id, index),
					name = tostring(job.name or "Job"),
					state = M.state(job.status),
					url = service.absolute_url(job.html_url),
					started_at = job.started_at,
					duration = pipeline_utils.duration(job.started_at, job.completed_at),
				})
			end
			local stage_state = #jobs > 0 and pipeline_utils.aggregate_state(jobs) or M.state(run.status)
			local detailed = vim.tbl_extend("force", {}, pipeline)
			detailed.name = tostring(run.name or "") ~= "" and tostring(run.name) or pipeline.name
			detailed.state = M.state(run.status)
			detailed.job_count = #jobs
			detailed.stages = {
				{ name = nil, state = stage_state, jobs = jobs },
			}
			on_done(detailed, nil)
		end)
	end)
	return requests
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(log: PullsLog|nil, err: string|nil, status?: integer)
---@return { cancel: fun() }|nil
function M.fetch_job_log(context, pipeline, job, on_done)
	local base = repo_endpoint(context)
	local job_id = tonumber(job.id)
	if base == nil or M.parse_run_number(context, pipeline) == nil or job_id == nil then
		on_done(nil, "Invalid Forgejo Actions job")
		return nil
	end
	return service.request_text(
		"GET",
		string.format("%s/actions/jobs/%d/logs", base, job_id),
		function(raw, err, status)
			on_done(raw and { raw = raw } or nil, err, status)
		end
	)
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.cancel(context, pipeline, on_done)
	local base = repo_endpoint(context)
	if not base or not M.parse_run_number(context, pipeline) then
		on_done(false, "Invalid Forgejo Actions run")
		return nil
	end
	local requests = request_scope.new()
	requests.run(function(done)
		return resolve_run(context, pipeline, done)
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
