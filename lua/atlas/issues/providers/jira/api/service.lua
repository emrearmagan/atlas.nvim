local M = {}

local cache = require("atlas.core.cache")
local config = require("atlas.issues.providers.jira.api.config")
local http = require("atlas.core.http")
local memory_cache = require("atlas.core.memory_cache")
local logger = require("atlas.core.logger")

---@return string, string, string|nil
local function get_auth()
	local jira = config.jira_config()
	local base_url = jira.base_url
	local email = jira.email or ""
	local token = jira.token

	if not base_url or base_url == "" or not token or token == "" then
		return "", "", "Missing Jira credentials in config (providers.jira.base_url, providers.jira.token)"
	end
	if jira.auth_method ~= "bearer" and email == "" then
		return "", "", "Missing Jira credentials in config (providers.jira.email)"
	end

	return base_url, email, nil
end

---@return table<string, string>
local function build_headers()
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
local function api_path()
	local version = "3"
	if config.jira_config().api_type == "server" then
		version = "2"
	end
	return "/rest/api/" .. version
end

---@return number
local function cache_ttl()
	return tonumber(config.jira_config().cache_ttl) or 300
end

function M.clear_memory_cache()
	memory_cache.clear_prefix("jira:")
end

---@param key string
---@return any|nil, boolean
function M.get_memory_cache(key)
	if cache_ttl() <= 0 then
		return nil, false
	end

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
	if cache_ttl() <= 0 then
		return
	end
	memory_cache.set(key, value, ttl or cache_ttl())
end

---@param key string
---@return any|nil
function M.get_cache(key)
	if cache_ttl() <= 0 then
		return nil
	end
	local entry = cache.get(key)
	return entry and entry.value or nil
end

---@param key string
---@param value any
function M.set_cache(key, value)
	if cache_ttl() <= 0 then
		return
	end
	cache.set(key, value, cache_ttl())
end

---@param method string
---@param endpoint string
---@param data table|nil
---@param on_done fun(result: table|nil, err: string|nil)
---@param ctx table|nil   optional extra context merged into the request log line (e.g. { action, issue_key, ... })
---@return { job_id: integer, cancel: fun() }|nil
function M.request(method, endpoint, data, on_done, ctx)
	local _, _, auth_err = get_auth()
	if auth_err then
		logger.logerror("Jira auth missing", { error = auth_err })
		on_done(nil, auth_err)
		return nil
	end

	local url = M.base_url() .. api_path() .. endpoint
	local headers = build_headers()
	local payload = nil
	if data ~= nil then
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
			logger.logerror(message .. " failed", vim.tbl_extend("force", {}, log, { error = tostring(err) }))
			on_done(nil, err)
			return
		end

		if type(result) ~= "table" then
			logger.logerror(
				message .. " failed",
				vim.tbl_extend("force", {}, log, { error = "Jira response is not a JSON object" })
			)
			on_done(nil, "Jira response is not a JSON object")
			return
		end

		if result.errorMessage or result.errorMessages or result.errors then
			local messages = {}
			if result.errorMessage then
				table.insert(messages, result.errorMessage)
			end
			for _, msg in ipairs(result.errorMessages or {}) do
				table.insert(messages, msg)
			end
			for k, v in pairs(result.errors or {}) do
				table.insert(messages, k .. ": " .. v)
			end
			if #messages > 0 then
				logger.logerror(
					message .. " failed",
					vim.tbl_extend("force", {}, log, { error = table.concat(messages, "; ") })
				)
				on_done(nil, table.concat(messages, "; "))
				return
			end
		end

		on_done(result, nil)
	end)
end

return M
