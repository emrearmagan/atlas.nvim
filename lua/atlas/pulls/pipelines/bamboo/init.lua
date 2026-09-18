local M = {}

local http = require("atlas.core.http")
local logger = require("atlas.core.logger")
local actions = require("atlas.pulls.pipelines.bamboo.actions")
local pipeline_utils = require("atlas.pulls.pipelines.utils")

---@param value any
---@return table[]
local function as_list(value)
	if type(value) ~= "table" then
		return {}
	end
	if value[1] ~= nil or next(value) == nil then
		return value
	end
	return { value }
end

---@param result table
---@return "SUCCESSFUL"|"FAILED"|"INPROGRESS"|"STOPPED"|"UNKNOWN"
local function map_state(result)
	local life = tostring(result.lifeCycleState or ""):upper()
	if life == "INPROGRESS" or life == "QUEUED" or life == "PENDING" then
		return "INPROGRESS"
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

---@param host string
---@return string web_base, string api_base
local function resolve_base(host)
	host = host:gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
	local web_base = host:match("^https?://") and host or ("https://" .. host)
	return web_base, web_base .. "/rest/api/latest"
end

---@param web_base string
---@param body table|nil
---@return PullsPipelineStage[] stages
---@return integer job_count
local function parse_stages(web_base, body)
	local stages = {}
	local job_count = 0
	local raw_stages = ((body or {}).stages or {}).stage
	for _, stage in ipairs(as_list(raw_stages)) do
		local stage_name = stage.name and tostring(stage.name) or nil
		local jobs = {}
		local results = (stage.results or {}).result
		for _, result in ipairs(as_list(results)) do
			local plan_result_key = type(result.planResultKey) == "table" and result.planResultKey.key or nil
			local key = tostring(plan_result_key or result.key or result.buildResultKey or "")
			local plan = type(result.plan) == "table" and result.plan or {}
			table.insert(jobs, {
				id = key,
				name = tostring(plan.shortName or result.planName or key ~= "" and key or "Job"),
				state = map_state(result),
				provider_state = tostring(result.state or result.buildState or result.lifeCycleState or ""),
				url = key ~= "" and string.format("%s/browse/%s", web_base, key) or nil,
				started_at = result.buildStartedTime or result.prettyBuildStartedTime,
				duration = tonumber(result.buildDurationInSeconds),
			})
		end
		job_count = job_count + #jobs
		table.insert(stages, {
			name = stage_name,
			state = map_state(stage),
			jobs = jobs,
		})
	end
	return stages, job_count
end

---@param opts { host: string, user: string, password: string }
---@return PullsPipelineBackend
function M.new(opts)
	local web_base, api_base = resolve_base(opts.host)
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
		local function on_done(result, err)
			if err then
				context.error = err
				logger.logerror(message .. " failed", context)
			end
			callback(result, err)
		end

		logger.loginfo(message, context)
		local send = text and http.curl_text_request or http.curl_request
		return send(method, url, headers, nil, on_done)
	end

	local function fetch(pr, fetch_opts, on_done)
		local native = require("atlas.pulls.pipelines." .. pr.provider)
		return native.fetch(pr, fetch_opts, function(pipelines, err)
			if err then
				on_done(nil, err)
				return
			end
			local builds = {}
			for _, pipeline in ipairs(pipelines) do
				local key = result_key_from_url(pipeline.url, web_base)
				if key then
					table.insert(builds, vim.tbl_extend("force", pipeline, { id = key }))
				end
			end
			on_done(builds, nil)
		end)
	end

	local function fetch_details(_pr, pipeline, _opts, on_done)
		local url = string.format(
			"%s/result/%s.json?expand=stages.stage.results.result&max-results=1000&os_authType=basic",
			api_base,
			pipeline.id
		)
		return request("GET", url, "pipeline details", function(body, err)
			if err then
				on_done(pipeline, err)
				return
			end
			local detailed = vim.tbl_extend("force", {}, pipeline)
			detailed.state = map_state(body)
			detailed.stages, detailed.job_count = parse_stages(web_base, body)
			on_done(detailed, nil)
		end)
	end

	local function fetch_job_log(_pr, _pipeline, job, on_done)
		local key = job.id or ""
		local job_key = key:match("^(.*)%-%d+$")
		if not job_key then
			on_done(nil, "Invalid Bamboo job identifier")
			return nil
		end

		local url = string.format("%s/download/%s/build_logs/%s.log", web_base, job_key, key)
		return request("GET", url, "job log", on_done, true)
	end

	local function fetch_commit_status(commit, _opts, on_done)
		local url = string.format("%s/result/byCheckoutChangeset/%s?os_authType=basic", api_base, commit.hash)
		return request("GET", url, "commit status", function(body, err)
			if err then
				on_done(nil, nil, err)
				return
			end

			local latest = {}
			for _, result in ipairs(as_list(body.results.result)) do
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
		fetch_details = fetch_details,
		fetch_job_log = fetch_job_log,
		fetch_commit_status = fetch_commit_status,
		actions = actions.new(web_base, request),
	}
end

return M
