local requests = require("atlas.core.requests")
local json = require("atlas.core.json")
local pipeline_utils = require("atlas.pulls.pipelines.utils")
local service = require("atlas.pulls.providers.bitbucket.api.service")
local encode_path_segment = require("atlas.core.utils").url_encode

local M = {}

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
	elseif value == "NOT_RUN" then
		return "SKIPPED"
	elseif value == "STOPPED" then
		return type(state) == "table" and "CANCELED" or "STOPPED"
	elseif value == "EXPIRED" or value == "SUPERSEDED" then
		return "STOPPED"
	end

	local name = type(state) == "table" and tostring(state.name or ""):upper() or value
	if name == "PENDING" or name == "READY" or name == "IN_PROGRESS" or name == "INPROGRESS" then
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

---@param job table
---@return PullsPipelineJob
local function parse_job(job)
	return {
		id = tostring(job.uuid),
		name = tostring(job.name or "Job"),
		state = pipeline_state(job.state),
		started_at = job.started_on,
		duration = tonumber(job.duration_in_seconds),
	}
end

---@param result table
---@param name string|nil
---@return PullsPipeline
local function parse_pipeline(result, name)
	local target = json.safe_table(result.target)
	local commit = json.safe_table(target.commit)
	local number = tonumber(result.build_number)
	local links = json.safe_table(result.links)
	return {
		id = tostring(number),
		name = name or ("Pipeline #" .. tostring(number)),
		state = pipeline_state(result.state),
		url = json.safe_str(json.safe_table(links.html).href),
		number = number,
		commit = json.safe_str(commit.hash),
		branch = json.safe_str(target.ref_name) or json.safe_str(target.source),
		started_at = json.safe_str(result.created_on),
		title = json.safe_str(commit.message),
		stages = {},
	}
end

---@param result table|nil
---@return PullsPipeline[]
local function parse_pipelines(result)
	local pipelines = {}
	for index, status in ipairs((result or {}).values or {}) do
		local pipeline_url = tostring(status.url or "")
		local status_id = tostring(status.key or "")
		if status_id == "" then
			status_id = tostring(status.name or index)
		end
		table.insert(pipelines, {
			id = pipeline_id(pipeline_url) or ("status:" .. status_id),
			number = tonumber(pipeline_id(pipeline_url)),
			name = tostring(status.name or status.key or ""),
			state = pipeline_state(status.state),
			url = pipeline_url ~= "" and pipeline_url or nil,
			stages = {},
		})
	end
	return pipelines
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(pipeline: PullsPipeline|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_jobs(context, pipeline, on_done)
	local repo = tostring(context.repo_full_name or "")
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

		local jobs = {}
		for _, job in ipairs((result or {}).values or {}) do
			table.insert(jobs, parse_job(job))
		end
		pipeline.job_count = #jobs
		pipeline.stages = {
			{
				name = nil,
				state = pipeline_utils.aggregate_state(jobs),
				jobs = jobs,
			},
		}
		on_done(pipeline, nil)
	end, { action = "Fetch pipeline jobs", repo = repo, pipeline_id = id })
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(pipeline: PullsPipeline|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_pipeline(context, pipeline, on_done)
	local repo = tostring(context.repo_full_name or "")
	local id = tostring(pipeline.id)
	if repo == "" or not id:match("^%d+$") then
		on_done(nil, "Missing Bitbucket pipeline identifier")
		return nil
	end

	local scope = requests.new()
	local endpoint = string.format("/repositories/%s/pipelines/%s", repo, id)
	scope.run(function(done)
		return service.request("GET", endpoint, nil, nil, done, {
			action = "Fetch pipeline details",
			repo = repo,
			pipeline_id = id,
		})
	end, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local selected = parse_pipeline(result, pipeline.name)
		selected.id = id
		selected.number = selected.number or tonumber(id)
		selected.url = selected.url or string.format("https://bitbucket.org/%s/pipelines/results/%s", repo, selected.id)
		scope.run(function(done)
			return fetch_jobs(context, selected, done)
		end, on_done)
	end)
	return scope
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_history(context, pipeline, on_done)
	local pr = type(context.target) == "table" and context.target.source and context.target or nil
	local repo = tostring(context.repo_full_name or "")
	local id = tostring(pipeline.id)
	if repo == "" or not id:match("^%d+$") then
		on_done(nil, "No build history available for this Bitbucket status")
		return nil
	end

	local scope = requests.new()
	local request_context = { action = "Fetch pipeline history", repo = repo, pipeline_id = id }
	scope.run(function(done)
		local endpoint = string.format("/repositories/%s/pipelines/%s", repo, id)
		return service.request("GET", endpoint, nil, nil, done, request_context)
	end, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local pipeline_target = json.safe_table(result.target)
		local selector = json.safe_table(pipeline_target.selector)
		local branch = json.safe_str(pipeline_target.ref_name) or json.safe_str(pipeline_target.source)
		local pullrequest = json.safe_str(json.safe_table(pipeline_target.pullrequest).id)
		if pipeline_target.type == "pipeline_pullrequest_target" or selector.type == "pull-requests" then
			if not pullrequest then
				on_done(nil, "Bitbucket did not return the pipeline's pull request identifier")
				return
			elseif pr and pullrequest ~= tostring(pr.id) then
				on_done(nil, "This pipeline belongs to another pull request")
				return
			end
		end
		if not branch and not selector.type then
			on_done(nil, "Missing Bitbucket pipeline history scope")
			return
		end

		local fields = "values.build_number,values.state,values.target,values.created_on,values.links.html"
		local endpoint =
			string.format("/repositories/%s/pipelines/?pagelen=30&sort=-created_on&fields=%s", repo, fields)
		local filters = {
			["target.ref_name"] = pipeline_target.ref_name,
			["target.branch"] = pipeline_target.source,
			["target.ref_type"] = pipeline_target.ref_type,
			["target.selector.type"] = selector.type,
			["target.selector.pattern"] = selector.pattern,
		}
		for key, value in pairs(filters) do
			if json.safe_str(value) then
				endpoint = endpoint .. "&" .. key .. "=" .. encode_path_segment(tostring(value))
			end
		end

		scope.run(function(done)
			return service.request("GET", endpoint, nil, nil, done, request_context)
		end, function(page, page_err)
			if page_err then
				on_done(nil, page_err)
				return
			end
			local history = {}
			local missing_pullrequest = false
			for _, item in ipairs(page.values or {}) do
				local candidate = json.safe_table(item.target)
				local candidate_selector = json.safe_table(candidate.selector)
				local candidate_branch = json.safe_str(candidate.ref_name) or json.safe_str(candidate.source)
				local candidate_pr = json.safe_str(json.safe_table(candidate.pullrequest).id)
				if
					candidate.type == pipeline_target.type
					and candidate.ref_type == pipeline_target.ref_type
					and candidate_branch == branch
					and candidate_selector.type == selector.type
					and candidate_selector.pattern == selector.pattern
					and tonumber(item.build_number)
				then
					if candidate_pr == pullrequest then
						local summary = parse_pipeline(item, pipeline.name)
						summary.url = summary.url
							or string.format("https://bitbucket.org/%s/pipelines/results/%s", repo, summary.id)
						table.insert(history, summary)
					elseif pullrequest and not candidate_pr then
						missing_pullrequest = true
					end
				end
			end
			if #history == 0 and missing_pullrequest then
				on_done(nil, "Bitbucket did not return pull request identifiers for recent builds")
				return
			end
			on_done(history, nil)
		end)
	end)
	return scope
end

---@param context PullsPipelineContext
---@param opts { force_refresh?: boolean|nil, pipeline?: PullsPipeline }|nil
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(context, opts, on_done)
	local target = context.target
	local selected = (opts or {}).pipeline or (type(target) == "table" and target.stages and target or nil)
	if selected then
		---@cast selected PullsPipeline
		return fetch_pipeline(context, selected, function(pipeline, err)
			on_done(pipeline and { pipeline } or nil, err)
		end)
	end

	local pr = type(target) == "table" and target.source and target or nil
	if not pr then
		local repo = context.repo_full_name
		local branch = type(target) == "string" and target or nil
		if repo == "" or not branch or branch == "" then
			on_done(nil, "Missing pipeline repository or branch")
			return nil
		end
		local endpoint = string.format(
			"/repositories/%s/pipelines/?pagelen=1&sort=-created_on&target.branch=%s",
			repo,
			encode_path_segment(branch)
		)
		local key = "bitbucket:branch:pipelines:" .. endpoint
		if not (opts or {}).force_refresh then
			local cached, ok = service.get_cache(key)
			if ok then
				on_done(cached, nil)
				return nil
			end
		end

		local scope = requests.new()
		scope.run(function(done)
			return service.request("GET", endpoint, nil, nil, done, {
				action = "Fetch branch pipeline",
				repo = repo,
				branch = branch,
			})
		end, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			local latest = json.safe_table(json.safe_table(result).values)[1]
			if not latest then
				service.set_cache(key, {})
				on_done({}, nil)
				return
			end
			local pipeline = parse_pipeline(latest)
			pipeline.url = pipeline.url
				or string.format("https://bitbucket.org/%s/pipelines/results/%s", repo, pipeline.id)
			scope.run(function(done)
				return fetch_jobs(context, pipeline, done)
			end, function(result_pipeline, jobs_err)
				if jobs_err then
					on_done(nil, jobs_err)
					return
				end
				local pipelines = { result_pipeline }
				service.set_cache(key, pipelines)
				on_done(pipelines, nil)
			end)
		end)
		return scope
	end

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

	local scope = requests.new()
	scope.run(function(done)
		return service.fetch_all_values(
			url,
			done,
			{ action = "Fetch PR pipelines", repo = pr.repo_full_name, id = pr.id }
		)
	end, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local pipelines = parse_pipelines(result)
		local starts = {}
		for index, pipeline in ipairs(pipelines) do
			starts[tostring(index)] = function(done)
				return fetch_jobs(context, pipeline, done)
			end
		end
		scope.all(starts, function(_, errors)
			for _, error in pairs(errors) do
				on_done(nil, error)
				return
			end
			service.set_cache(key, pipelines)
			on_done(pipelines, nil)
		end)
	end)
	return scope
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(file: { path: string, content: string }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_config(context, pipeline, on_done)
	local repo = tostring(context.repo_full_name or "")
	local id = tostring(pipeline.id)
	if repo == "" or not id:match("^%d+$") then
		on_done(nil, "No configuration file available for this pipeline")
		return nil
	end

	local scope = requests.new()
	local endpoint = string.format("/repositories/%s/pipelines/%s", repo, id)
	scope.run(function(done)
		return service.request("GET", endpoint, nil, nil, done, {
			action = "Fetch pipeline configuration",
			repo = repo,
			pipeline_id = id,
		})
	end, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local commit = json.safe_str(json.safe_table(json.safe_table(result.target).commit).hash)
		if not commit then
			on_done(nil, "Missing pipeline commit")
			return
		end
		local path = json.safe_str(json.safe_table(result.configuration_file).path) or "bitbucket-pipelines.yml"
		local source =
			string.format("/repositories/%s/src/%s/%s", repo, commit, path:gsub("[^/]+", encode_path_segment))
		scope.run(function(done)
			return service.request_text("GET", source, { Accept = "*/*" }, nil, done, {
				action = "Fetch pipeline configuration file",
				repo = repo,
				pipeline_id = id,
			})
		end, function(content, source_err)
			if source_err then
				on_done(nil, source_err)
				return
			end
			on_done({ path = path, content = content or "" }, nil)
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
	local repo = tostring(context.repo_full_name or "")
	local id = tostring(pipeline.id)
	local job_id = job.id
	if repo == "" or not id:match("^%d+$") or job_id == "" then
		on_done(nil, "Missing Bitbucket pipeline job identifier")
		return nil
	end

	local endpoint = string.format("/repositories/%s/pipelines/%s/steps/%s", repo, id, encode_path_segment(job_id))
	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		---@cast result table
		on_done(parse_job(result), nil)
	end, { action = "Fetch pipeline job", repo = repo, pipeline_id = id, job_id = job_id })
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(log: PullsLog|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_job_log(context, pipeline, job, on_done)
	local repo = tostring(context.repo_full_name or "")
	local id = tostring(pipeline.id)
	local job_id = job.id
	if repo == "" or not id:match("^%d+$") or job_id == "" then
		on_done(nil, "Missing Bitbucket pipeline job identifier")
		return nil
	end

	local endpoint = string.format("/repositories/%s/pipelines/%s/steps/%s/log", repo, id, encode_path_segment(job_id))
	return service.request_text("GET", endpoint, { Accept = "*/*" }, nil, function(raw, err)
		on_done(raw and { raw = raw } or nil, err)
	end, {
		action = "Fetch pipeline job log",
		repo = repo,
		pipeline_id = id,
		job_id = job_id,
	})
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.run_pipeline(context, pipeline, on_done)
	local repo = tostring(context.repo_full_name or "")
	local target = context.target
	local branch = pipeline.branch
		or (type(target) == "string" and target)
		or (type(target) == "table" and target.source and target.source.branch)
		or ""
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

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.stop_pipeline(context, pipeline, on_done)
	local repo = tostring(context.repo_full_name or "")
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
