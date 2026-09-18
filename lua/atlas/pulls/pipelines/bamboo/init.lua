local M = {}

local http = require("atlas.core.http")
local json = require("atlas.core.json")
local logger = require("atlas.core.logger")
local requests = require("atlas.core.requests")
local actions = require("atlas.pulls.pipelines.bamboo.actions")
local parser = require("atlas.pulls.pipelines.bamboo.parser")
local bitbucket = require("atlas.pulls.pipelines.bitbucket")
local pipeline_utils = require("atlas.pulls.pipelines.utils")

---@param result table
---@return PullsPipelineState
local function map_state(result)
	local life = tostring(result.lifeCycleState or ""):upper()
	if life == "INPROGRESS" or life == "QUEUED" or life == "PENDING" then
		return "INPROGRESS"
	end
	if result.continuable == true or result.notRunYet == true then
		return "MANUAL"
	end

	local state = tostring(result.state or result.buildState or ""):upper()
	if state == "SUCCESSFUL" or state == "SUCCESS" then
		return "SUCCESSFUL"
	end
	if state == "FAILED" or state == "ERROR" then
		return "FAILED"
	end
	if life == "NOTBUILT" then
		return "STOPPED"
	end
	return "UNKNOWN"
end

---@param url string|nil
---@param web_base string
---@return string|nil
local function result_key_from_url(url, web_base)
	if type(url) ~= "string" then
		return nil
	end
	local prefix = web_base:gsub("^https?://", "") .. "/browse/"
	url = url:gsub("^https?://", "")
	if url:sub(1, #prefix) ~= prefix then
		return nil
	end
	return url:sub(#prefix + 1):match("^([%w%-_.]+%-%d+)")
end

---@param pipelines PullsPipeline[]
---@param web_base string
---@return PullsPipeline[]
local function linked_builds(pipelines, web_base)
	local builds, seen = {}, {}
	for _, pipeline in ipairs(pipelines) do
		local candidates = {}
		for _, stage in ipairs(pipeline.stages or {}) do
			vim.list_extend(candidates, stage.jobs or {})
		end
		table.insert(candidates, pipeline)

		for _, candidate in ipairs(candidates) do
			local key = result_key_from_url(candidate.url, web_base)
			if key and not seen[key] then
				seen[key] = true
				table.insert(builds, vim.tbl_extend("force", {}, candidate, { id = key }))
			end
		end
	end
	return builds
end

---@param web_base string
---@param result table
---@return PullsPipelineJob
local function parse_job(web_base, result)
	local key = result.key
	local plan = result.plan or {}
	return {
		id = key,
		name = plan.shortName or result.planName or key,
		state = map_state(result),
		url = string.format("%s/browse/%s", web_base, key),
		started_at = result.buildStartedTime,
		duration = tonumber(result.buildDurationInSeconds),
	}
end

---@param web_base string
---@param result table
---@param name string
---@return PullsPipeline
local function parse_pipeline(web_base, result, name)
	local key = tostring(result.key)
	local plan = json.safe_table(result.plan)
	return {
		id = key,
		name = name,
		state = map_state(result),
		url = string.format("%s/browse/%s", web_base, key),
		number = tonumber(result.buildNumber or result.number) or tonumber(key:match("%-(%d+)$")),
		commit = json.safe_str(result.vcsRevisionKey),
		branch = json.safe_str(plan.vcsBranchName),
		started_at = json.safe_str(result.buildStartedTime),
		stages = {},
	}
end

---@param web_base string
---@param body table
---@return PullsPipelineStage[] stages
---@return integer job_count
local function parse_stages(web_base, body)
	local stages = {}
	local job_count = 0
	local raw_stages = (body.stages or {}).stage or {}
	for _, stage in ipairs(raw_stages) do
		local jobs = {}
		local results = (stage.results or {}).result or {}
		for _, result in ipairs(results) do
			table.insert(jobs, parse_job(web_base, result))
		end
		job_count = job_count + #jobs
		table.insert(stages, {
			name = stage.name,
			state = map_state(stage),
			jobs = jobs,
		})
	end
	return stages, job_count
end

---@param opts { host: string, user: string, password: string }
---@return PullsPipelineBackend
function M.new(opts)
	local host = opts.host:gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
	local web_base = host:match("^https?://") and host or ("https://" .. host)
	local api_base = web_base .. "/rest/api/latest"
	local headers = {
		Authorization = "Basic " .. vim.base64.encode(opts.user .. ":" .. opts.password),
		Accept = "application/json",
	}

	---@param method string
	---@param url string
	---@param label string
	---@param callback function
	---@param text boolean|nil
	---@return { cancel: fun() }|nil
	local function request(method, url, label, callback, text)
		local context = { method = method, endpoint = url }
		local message = "Bamboo " .. label .. " request"
		logger.loginfo(message, context)
		local send = text and http.curl_text_request or http.curl_request
		return send(method, url, headers, nil, function(result, err)
			if err then
				context.error = err
				logger.logerror(message .. " failed", context)
			end
			callback(result, err)
		end)
	end

	local function fetch_result(pipeline, on_done)
		local url = string.format(
			"%s/result/%s.json?expand=stages.stage.results.result&max-results=1000&os_authType=basic",
			api_base,
			pipeline.id
		)
		return request("GET", url, "pipeline details", function(body, err)
			if err then
				on_done(nil, err)
				return
			end
			for key, value in pairs(parse_pipeline(web_base, body, pipeline.name)) do
				pipeline[key] = value
			end
			pipeline.stages, pipeline.job_count = parse_stages(web_base, body)
			on_done(pipeline, nil)
		end)
	end

	---@param _context PullsPipelineContext
	---@param pipeline PullsPipeline
	---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
	---@return { cancel: fun() }|nil
	local function fetch_history(_context, pipeline, on_done)
		local key = pipeline.id:match("^(.*)%-%d+$")
		if not key then
			on_done(nil, "Invalid Bamboo pipeline identifier")
			return nil
		end

		local url = string.format(
			"%s/result/%s.json?expand=results.result&includeAllStates=true&start-index=0&max-results=30&os_authType=basic",
			api_base,
			key
		)
		return request("GET", url, "pipeline history", function(body, err)
			if err then
				on_done(nil, err)
				return
			end
			local history = {}
			for _, result in ipairs(json.safe_table(body.results).result or {}) do
				if tostring(result.key):match("^(.*)%-%d+$") == key then
					table.insert(history, parse_pipeline(web_base, result, pipeline.name))
				end
			end
			table.sort(history, function(a, b)
				return (a.number or 0) > (b.number or 0)
			end)
			on_done(history, nil)
		end)
	end

	local function fetch(context, fetch_opts, on_done)
		if context.provider ~= "bitbucket" then
			on_done(nil, "The Bamboo backend currently supports Bitbucket only.")
			return nil
		end

		local target = context.target
		local pipeline = (fetch_opts and fetch_opts.pipeline) or (type(target) == "table" and target.stages and target)
		if pipeline and pipeline.id:match("^[%w%-_]+%-%d+$") then
			return fetch_result(vim.tbl_extend("force", {}, pipeline), function(pipeline, err)
				on_done(pipeline and { pipeline } or nil, err)
			end)
		end

		local scope = requests.new()
		scope.run(function(done)
			return bitbucket.fetch(context, fetch_opts, done)
		end, function(pipelines, err)
			if err then
				on_done(nil, err)
				return
			end

			local builds = linked_builds(pipelines, web_base)
			local starts = {}
			for index, build in ipairs(builds) do
				starts[tostring(index)] = function(done)
					return fetch_result(build, done)
				end
			end
			scope.all(starts, function(_, errors)
				for _, error in pairs(errors) do
					on_done(nil, error)
					return
				end
				on_done(builds, nil)
			end)
		end)
		return scope
	end

	---@param _context PullsPipelineContext
	---@param pipeline PullsPipeline
	---@param on_done fun(file: { path: string, content: string }|nil, err: string|nil)
	---@return { cancel: fun() }|nil
	local function fetch_config(_context, pipeline, on_done)
		local key = pipeline.id:match("^(.*)%-%d+$")
		if not key then
			on_done(nil, "Invalid Bamboo pipeline identifier")
			return nil
		end

		local url = string.format("%s/plan/%s/specs?format=YAML", api_base, key)
		return request("GET", url, "plan configuration", function(body, err)
			if err then
				on_done(nil, err)
				return
			end
			local content = body.spec and body.spec.code
			if type(content) ~= "string" then
				on_done(nil, "Bamboo did not return a plan configuration")
				return
			end
			on_done({ path = key .. ".yaml", content = content }, nil)
		end)
	end

	---@param _context PullsPipelineContext
	---@param _pipeline PullsPipeline
	---@param job PullsPipelineJob
	---@param on_done fun(job: PullsPipelineJob|nil, err: string|nil)
	---@return { cancel: fun() }|nil
	local function fetch_job(_context, _pipeline, job, on_done)
		local url = string.format("%s/result/%s.json?os_authType=basic", api_base, job.id)
		return request("GET", url, "job details", function(body, err)
			if err then
				on_done(nil, err)
				return
			end
			on_done(parse_job(web_base, body), nil)
		end)
	end

	local function fetch_job_log(_context, _pipeline, job, on_done)
		local key = job.id or ""
		local job_key = key:match("^(.*)%-%d+$")
		if not job_key then
			on_done(nil, "Invalid Bamboo job identifier")
			return nil
		end

		local url = string.format("%s/download/%s/build_logs/%s.log", web_base, job_key, key)
		return request("GET", url, "job log", function(raw, err)
			on_done(raw and { raw = raw } or nil, err)
		end, true)
	end

	local function fetch_commit_status(commit, _opts, on_done)
		local url = string.format("%s/result/byCheckoutChangeset/%s?os_authType=basic", api_base, commit.hash)
		return request("GET", url, "commit status", function(body, err)
			if err then
				on_done(nil, nil, err)
				return
			end

			local latest = {}
			for _, result in ipairs(body.results.result or {}) do
				local plan_key, number = result.key:match("^(.*)%-(%d+)$")
				local build_number = tonumber(number)
				if not latest[plan_key] or build_number > latest[plan_key].number then
					latest[plan_key] = {
						number = build_number,
						state = map_state(result),
						url = web_base .. "/browse/" .. result.key,
					}
				end
			end

			local builds = {}
			for _, build in pairs(latest) do
				table.insert(builds, build)
			end
			local state = pipeline_utils.aggregate_state(builds)
			local build_url
			for _, build in ipairs(builds) do
				if build.state == state then
					build_url = build.url
					break
				end
			end
			on_done(state:lower(), build_url, nil)
		end)
	end

	return {
		fetch = fetch,
		fetch_history = fetch_history,
		fetch_config = fetch_config,
		fetch_job = fetch_job,
		fetch_job_log = fetch_job_log,
		parse = parser.parse,
		fetch_commit_status = fetch_commit_status,
		actions = actions.new(web_base, request),
	}
end

return M
