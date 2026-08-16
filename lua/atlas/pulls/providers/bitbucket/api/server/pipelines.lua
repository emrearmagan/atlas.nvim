local M = {}

local service = require("atlas.pulls.providers.bitbucket.api.service")

---@param value any
---@return "SUCCESSFUL"|"FAILED"|"INPROGRESS"|"STOPPED"|"UNKNOWN"
local function pipeline_state(value)
	local state = tostring(value or ""):upper()
	if state == "SUCCESSFUL" then
		return "SUCCESSFUL"
	elseif state == "FAILED" or state == "ERROR" then
		return "FAILED"
	elseif state == "INPROGRESS" or state == "IN_PROGRESS" or state == "RUNNING" then
		return "INPROGRESS"
	elseif state == "CANCELLED" or state == "CANCELED" or state == "STOPPED" then
		return "STOPPED"
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

	local has_failed, has_inprogress, has_stopped, has_success = false, false, false, false
	local first_url
	for _, item in ipairs(values) do
		local state = pipeline_state(item.state)
		if first_url == nil and item.url and item.url ~= "" then
			first_url = tostring(item.url)
		end
		if state == "FAILED" then
			has_failed = true
		elseif state == "INPROGRESS" then
			has_inprogress = true
		elseif state == "STOPPED" then
			has_stopped = true
		elseif state == "SUCCESSFUL" then
			has_success = true
		end
	end

	if has_failed then
		return "failed", first_url
	elseif has_inprogress then
		return "inprogress", first_url
	elseif has_stopped then
		return "stopped", first_url
	elseif has_success then
		return "successful", first_url
	end
	return "unknown", first_url
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pipelines(pr, _opts, on_done) ---@diagnostic disable-line: unused-local
	local commit_hash = tostring(pr and pr.source and pr.source.commit_hash or "")
	if commit_hash == "" then
		on_done({}, nil)
		return nil
	end

	local url = service.server_url("/rest/build-status/1.0", "/commits/" .. commit_hash)
	return service.request("GET", url, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		---@type PullsPipeline[]
		local pipelines = {}
		for _, item in ipairs((type(result) == "table" and result.values) or {}) do
			local status = type(item) == "table" and item or {}
			local provider_state = tostring(status.state or "")
			local status_url = tostring(status.url or "")
			table.insert(pipelines, {
				name = tostring(status.name or status.key or ""),
				state = pipeline_state(provider_state),
				provider_state = provider_state,
				url = status_url ~= "" and status_url or nil,
				key = tostring(status.key or ""),
				-- Deliberately omit provider_id. Bitbucket Server build statuses do
				-- not identify Cloud pipelines and must not enable run/stop actions.
				provider_id = nil,
				commit_hash = commit_hash,
				jobs = {},
			})
		end

		on_done(pipelines, nil)
	end, {
		action = "Bitbucket Server build statuses",
		commit = commit_hash,
	})
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
	local key = "bitbucket-server:commit:statuses:" .. statuses_url
	if not force then
		local cached, ok = service.get_cache(key)
		if ok then
			local values = (cached or {}).values or cached or {}
			local status, url = aggregate_statuses(values)
			on_done(status, url, nil)
			return nil
		end
	end

	return service.request("GET", statuses_url, nil, nil, function(result, err)
		if err then
			on_done(nil, nil, err)
			return
		end

		service.set_cache(key, result, service.cache_ttl())
		local values = (type(result) == "table" and result.values) or {}
		local status, url = aggregate_statuses(values)
		on_done(status, url, nil)
	end, { action = "Bitbucket Server commit status" })
end

return M
