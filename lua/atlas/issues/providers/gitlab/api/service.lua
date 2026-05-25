local M = {}

local config = require("atlas.config")
local http = require("atlas.core.http")
local memory_cache = require("atlas.core.memory_cache")
local logger = require("atlas.core.logger")

local API_PATH = "/api/v4"

---@return AtlasGitLabIssuesConfig
function M.gitlab_config()
	local opts = config.options
	local issues = opts and opts.issues or nil
	return (issues and issues.providers and issues.providers.gitlab) or {}
end

---@return string base_url, string|nil err
function M.get_auth()
	local cfg = M.gitlab_config()
	local base_url = cfg.base_url
	local token = cfg.token
	if not base_url or base_url == "" or not token or token == "" then
		return "",
			"Missing GitLab credentials in config (issues.providers.gitlab.base_url, issues.providers.gitlab.token)"
	end
	return base_url, nil
end

---@return string
function M.base_url()
	local raw = tostring(M.gitlab_config().base_url or "")
	return (raw:gsub("/+$", ""))
end

---@param endpoint string
---@return string
function M.url(endpoint)
	return M.base_url() .. API_PATH .. endpoint
end

---@return table<string, string>
function M.build_headers()
	return {
		["PRIVATE-TOKEN"] = tostring(M.gitlab_config().token or ""),
		["Content-Type"] = "application/json",
		Accept = "application/json",
	}
end

---@return number
function M.cache_ttl()
	return tonumber(M.gitlab_config().cache_ttl) or 300
end

function M.clear_memory_cache()
	memory_cache.clear_all()
end

---@param key string
---@return any|nil, boolean
function M.get_memory_cache(key)
	local entry = memory_cache.get(key)
	if not entry then
		return nil, false
	end
	return entry.value, true
end

---@param key string
---@param value any
---@param ttl number|nil
function M.set_memory_cache(key, value, ttl)
	memory_cache.set(key, value, ttl or M.cache_ttl())
end

---@param key string
function M.delete_memory_cache(key)
	memory_cache.delete(key)
end

---@param str string
---@return string
function M.url_encode(str)
	return (str:gsub("([^%w%-_.~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

---@param value any
---@return string|nil
local function extract_error_message(value)
	if value == nil or value == vim.NIL then
		return nil
	end
	if type(value) == "string" then
		return value
	end
	if type(value) == "table" then
		local parts = {}
		for k, v in pairs(value) do
			if type(v) == "table" then
				for _, m in ipairs(v) do
					table.insert(parts, tostring(k) .. ": " .. tostring(m))
				end
			else
				table.insert(parts, tostring(k) .. ": " .. tostring(v))
			end
		end
		if #parts > 0 then
			return table.concat(parts, "; ")
		end
	end
	return nil
end

---@param method string
---@param endpoint string
---@param data table|nil
---@param on_done fun(result: any, err: string|nil)
---@param ctx table|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.request(method, endpoint, data, on_done, ctx)
	local _, auth_err = M.get_auth()
	if auth_err then
		logger.logerror("GitLab auth missing", { error = auth_err })
		on_done(nil, auth_err)
		return nil
	end

	local url = M.url(endpoint)
	local headers = M.build_headers()
	local payload = nil
	if type(data) == "table" then
		local ok, encoded = pcall(vim.fn.json_encode, data)
		if not ok then
			logger.logerror("GitLab payload encode failed", {
				method = method,
				endpoint = endpoint,
				error = tostring(encoded),
			})
			on_done(nil, "Request payload is invalid")
			return nil
		end
		payload = encoded
	end

	local log = vim.tbl_extend("keep", { method = method, endpoint = endpoint }, ctx or {})
	local message = log.action or "GitLab issues request"
	log.action = nil
	logger.loginfo(message, log)

	return http.curl_request(method, url, headers, payload, function(result, err)
		if err then
			logger.logerror("GitLab request failed", {
				method = method,
				endpoint = endpoint,
				error = tostring(err),
			})
			on_done(nil, err)
			return
		end

		if type(result) == "table" and not vim.islist(result) then
			local msg = extract_error_message(result.message) or extract_error_message(result.error_description)
			if msg == nil and result.error ~= nil and result.error ~= vim.NIL then
				msg = tostring(result.error)
			end
			if msg ~= nil then
				logger.logerror("GitLab API error", { method = method, endpoint = endpoint, error = msg })
				on_done(nil, msg)
				return
			end
		end

		on_done(result, nil)
	end)
end

---@param query string
---@param variables table|nil
---@param on_done fun(result: any, err: string|nil)
---@param ctx table|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.graphql(query, variables, on_done, ctx)
	local url = M.base_url() .. "/api/graphql"
	local headers = M.build_headers()
	local payload = vim.fn.json_encode({ query = query, variables = variables or vim.empty_dict() })
	local log = vim.tbl_extend("keep", { transport = "graphql" }, ctx or {})
	local message = log.action or "GitLab issues request"
	log.action = nil
	logger.loginfo(message, log)
	return http.curl_request("POST", url, headers, payload, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		if type(result) == "table" and type(result.errors) == "table" and #result.errors > 0 then
			on_done(nil, tostring(result.errors[1].message or "GraphQL error"))
			return
		end
		on_done(type(result) == "table" and result.data or nil, nil)
	end)
end

return M
