local M = {}

local config = require("atlas.config")
local logger = require("atlas.core.logger")
local http = require("atlas.core.http")
local memory_cache = require("atlas.core.memory_cache")

local API_BASE = "https://api.bitbucket.org/2.0"

---@param err any
---@return string
local function sanitize_error(err)
	return (tostring(err or ""):gsub("[\r\n]+", " | "))
end

---@return string, string, string|nil
function M.get_auth()
	local bb = (config.options and config.options.pulls and config.options.pulls.providers and config.options.pulls.providers.bitbucket) or {}
	local user = tostring(bb.user or "")
	local token = tostring(bb.token or "")

	if not user or user == "" or not token or token == "" then
		return "", "", "Missing Bitbucket credentials in config (bitbucket.user / bitbucket.token)"
	end

	return user, token, nil
end

---@param user string
---@param token string
---@return table<string, string>
function M.build_headers(user, token)
	local auth = vim.base64.encode(string.format("%s:%s", user or "", token or ""))
	return {
		Authorization = "Basic " .. auth,
		["Content-Type"] = "application/json",
		Accept = "application/json",
	}
end

---@return string
function M.base_url()
	return API_BASE
end

---@param endpoint string
---@return string
function M.url(endpoint)
	if endpoint:sub(1, 1) ~= "/" then
		endpoint = "/" .. endpoint
	end
	return API_BASE .. endpoint
end

---@return number
function M.cache_ttl()
	local bb = config.options and config.options.pulls and config.options.pulls.providers and config.options.pulls.providers.bitbucket
	return ((bb and bb.cache_ttl) or 300)
end

function M.clear_cache()
	memory_cache.clear_all()
end

---@param key string
---@return any|nil, boolean
function M.get_cache(key)
	local entry = memory_cache.get(key)
	if not entry then
		return nil, false
	end

	return entry.value, true
end

---@param key string
---@param value any
---@param ttl number|nil
function M.set_cache(key, value, ttl)
	memory_cache.set(key, value, ttl or M.cache_ttl())
end

---@param key string
function M.delete_cache(key)
	memory_cache.delete(key)
end

---@param result any
---@return string|nil
function M.api_error_message(result)
	if type(result) ~= "table" or result.error == nil then
		return nil
	end
	if type(result.error) == "table" and result.error.message then
		return tostring(result.error.message)
	end
	if type(result.error) == "string" then
		return result.error
	end
	return "Bitbucket API error"
end

---@param method string "GET"|"POST"|"PUT"|"DELETE"
---@param url string Full URL or endpoint
---@param headers table|nil Optional headers (will merge with auth headers)
---@param body string|nil Optional JSON body
---@param callback fun(result: table|nil, err: string|nil)
---@param ctx table|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.request(method, url, headers, body, callback, ctx)
	local user, token, auth_err = M.get_auth()
	if auth_err then
		callback(nil, sanitize_error(auth_err))
		return nil
	end

	local request_headers = M.build_headers(user, token)
	if headers then
		for k, v in pairs(headers) do
			request_headers[k] = v
		end
	end

	-- If url doesn't start with http, treat it as an endpoint
	local full_url = url
	if not url:match("^https?://") then
		full_url = M.url(url)
	end

	local log = vim.tbl_extend("keep", { method = method, endpoint = full_url }, ctx or {})
	local message = log.action or "Bitbucket request"
	log.action = nil
	logger.loginfo(message, log)

	return http.curl_request(method, full_url, request_headers, body, function(result, err)
		if err then
			local safe_err = sanitize_error(err)
			logger.logerror("Bitbucket request failed", {
				method = method,
				url = full_url,
				error = safe_err,
			})
			callback(nil, safe_err)
			return
		end

		if type(result) ~= "table" then
			callback(nil, "Bitbucket response is not a JSON object")
			return
		end

		local api_err = M.api_error_message(result)
		if api_err then
			api_err = sanitize_error(api_err)
			logger.logerror("Bitbucket API error", {
				method = method,
				url = full_url,
				error = api_err,
			})
			callback(nil, api_err)
			return
		end

		callback(result, nil)
	end)
end

---@param method string "GET"|"POST"|"PUT"|"DELETE"
---@param url string Full URL or endpoint
---@param headers table|nil Optional headers (will merge with auth headers)
---@param body string|nil Optional body
---@param callback fun(text: string|nil, err: string|nil)
---@param ctx table|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.request_text(method, url, headers, body, callback, ctx)
	local user, token, auth_err = M.get_auth()
	if auth_err then
		callback(nil, sanitize_error(auth_err))
		return nil
	end

	local request_headers = M.build_headers(user, token)
	if headers then
		for k, v in pairs(headers) do
			request_headers[k] = v
		end
	end

	-- If url doesn't start with http, treat it as an endpoint
	local full_url = url
	if not url:match("^https?://") then
		full_url = M.url(url)
	end

	local log = vim.tbl_extend("keep", { method = method, endpoint = full_url }, ctx or {})
	local message = log.action or "Bitbucket request"
	log.action = nil
	logger.loginfo(message, log)

	return http.curl_text_request(method, full_url, request_headers, body, function(text, err)
		if err then
			local safe_err = sanitize_error(err)
			logger.logerror("Bitbucket request failed", {
				method = method,
				url = full_url,
				error = safe_err,
			})
			callback(nil, safe_err)
			return
		end

		callback(text, nil)
	end)
end

return M
