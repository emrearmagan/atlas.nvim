local M = {}

local config = require("atlas.issues.providers.jira.api.config")
local http = require("atlas.core.http")
local memory_cache = require("atlas.core.memory_cache")
local logger = require("atlas.core.logger")

---@return string, string, string|nil
function M.get_auth()
	local jira = config.jira_config()
	local base_url = jira.base_url
	local email = jira.email
	local token = jira.token

	if not base_url or base_url == "" or not email or email == "" or not token or token == "" then
		return "",
			"",
			"Missing Jira credentials in config (issues.providers.jira.base_url, issues.providers.jira.email, issues.providers.jira.token)"
	end

	return base_url, email, nil
end

---@return table<string, string>
function M.build_headers()
	local jira = config.jira_config()
	local email = jira.email or ""
	local token = jira.token or ""
	local auth_header = "Basic " .. vim.base64.encode(string.format("%s:%s", email, token))
	if jira.auth_method == "bearer" then
		auth_header = "Bearer " .. token
	end
	return {
		authorization = auth_header,
		["Content-Type"] = "application/json",
		Accept = "application/json",
	}
end

---@return string
function M.base_url()
	return tostring(config.jira_config().base_url or "")
end

---@return string
function M.api_path()
	local version = "3"
	if config.jira_config().api_type == "server" then
		version = "2"
	end
	return "/rest/api/" .. version
end

---@param endpoint string
---@return string
function M.url(endpoint)
	return M.base_url() .. M.api_path() .. endpoint
end

---@return number
function M.cache_ttl()
	return tonumber(config.jira_config().cache_ttl) or 300
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

---@param method string
---@param endpoint string
---@param data table|nil
---@param on_done fun(result: table|nil, err: string|nil)
---@param ctx table|nil   optional extra context merged into the request log line (e.g. { action, issue_key, ... })
---@return { job_id: integer, cancel: fun() }|nil
function M.request(method, endpoint, data, on_done, ctx)
	local _, _, auth_err = M.get_auth()
	if auth_err then
		logger.logerror("Jira auth missing", { error = auth_err })
		on_done(nil, auth_err)
		return nil
	end

	local url = M.url(endpoint)
	local headers = M.build_headers()
	local payload = nil
	if type(data) == "table" then
		local ok, encoded = pcall(vim.fn.json_encode, data)
		if not ok then
			logger.logerror("Jira payload encode failed", {
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
	local message = log.action or "Jira request"
	log.action = nil
	logger.loginfo(message, log)
	return http.curl_request(method, url, headers, payload, function(result, err)
		if err then
			logger.logerror("Jira request failed", {
				method = method,
				endpoint = endpoint,
				error = tostring(err),
			})
			on_done(nil, err)
			return
		end

		if type(result) ~= "table" then
			logger.logerror("Jira response parse failed", {
				method = method,
				endpoint = endpoint,
				error = "Jira response is not a JSON object",
			})
			on_done(nil, "Jira response is not a JSON object")
			return
		end

		if result.errorMessages or result.errors then
			local messages = {}
			for _, msg in ipairs(result.errorMessages or {}) do
				table.insert(messages, msg)
			end
			for k, v in pairs(result.errors or {}) do
				table.insert(messages, k .. ": " .. v)
			end
			if #messages > 0 then
				logger.logerror("Jira API returned errors", {
					method = method,
					endpoint = endpoint,
					error = table.concat(messages, "; "),
				})
				on_done(nil, table.concat(messages, "; "))
				return
			end
		end

		on_done(result, nil)
	end)
end

return M
