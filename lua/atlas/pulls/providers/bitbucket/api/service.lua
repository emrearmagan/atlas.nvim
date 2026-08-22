local M = {}

local cache = require("atlas.core.cache")
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
	local bb = config.provider_options("bitbucket") or {}
	local user = tostring(bb.user or "")
	local token = tostring(bb.token or "")

	if not user or user == "" or not token or token == "" then
		return "", "", "Missing Bitbucket credentials in config (providers.bitbucket.user / providers.bitbucket.token)"
	end

	return user, token, nil
end

---@param user string
---@param token string
---@param has_body boolean|nil
---@return table<string, string>
function M.build_headers(user, token, has_body)
	local auth = vim.base64.encode(string.format("%s:%s", user or "", token or ""))
	return {
		Authorization = "Basic " .. auth,
		["Content-Type"] = has_body and "application/json" or nil,
		Accept = "application/json",
	}
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
	local bb = config.provider_options("bitbucket")
	return tonumber(bb and bb.cache_ttl) or 300
end

function M.clear_cache()
	memory_cache.clear_prefix("bitbucket:")
	cache.clear_prefix("bitbucket:prs:")
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
---@return any|nil, boolean
function M.get_persistent_cache(key)
	local entry = cache.get(key)
	if not entry or entry.value == nil then
		return nil, false
	end
	return entry.value, true
end

---@param key string
---@param value any
---@param ttl number|nil
function M.set_persistent_cache(key, value, ttl)
	cache.set(key, value, ttl or M.cache_ttl())
end

---@param result table
---@return string|nil
function M.api_error_message(result)
	if result.error == nil then
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
		local err = sanitize_error(auth_err)
		logger.logerror("Bitbucket auth missing", { error = err })
		callback(nil, err)
		return nil
	end

	local request_headers = M.build_headers(user, token, body ~= nil)
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
			logger.logerror("Bitbucket request failed", vim.tbl_extend("force", {}, log, { error = safe_err }))
			callback(nil, safe_err)
			return
		end

		if type(result) ~= "table" then
			logger.logerror(
				"Bitbucket response invalid",
				vim.tbl_extend("force", {}, log, { error = "Response is not a JSON object" })
			)
			callback(nil, "Bitbucket response is not a JSON object")
			return
		end

		local api_err = M.api_error_message(result)
		if api_err then
			api_err = sanitize_error(api_err)
			logger.logerror("Bitbucket API error", vim.tbl_extend("force", {}, log, { error = api_err }))
			callback(nil, api_err)
			return
		end

		callback(result, nil)
	end)
end

---@param url string
---@param on_done fun(result: { values: table[] }|nil, err: string|nil)
---@return { cancel: fun() }
function M.fetch_all_values(url, on_done)
	local values = {}
	local current
	local cancelled = false

	local function fetch_page(page_url)
		if cancelled then
			return
		end
		current = M.request("GET", page_url, nil, nil, function(result, err)
			if cancelled then
				return
			end
			if err then
				on_done(nil, err)
				return
			end
			vim.list_extend(values, result.values or {})
			local next_url = type(result.next) == "string" and result.next or ""
			if next_url == "" then
				on_done({ values = values }, nil)
				return
			end
			fetch_page(next_url)
		end)
	end

	fetch_page(url)
	return {
		cancel = function()
			cancelled = true
			if current then
				current.cancel()
			end
		end,
	}
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
		local err = sanitize_error(auth_err)
		logger.logerror("Bitbucket auth missing", { error = err })
		callback(nil, err)
		return nil
	end

	local request_headers = M.build_headers(user, token, body ~= nil)
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
			logger.logerror("Bitbucket request failed", vim.tbl_extend("force", {}, log, { error = safe_err }))
			callback(nil, safe_err)
			return
		end

		callback(text, nil)
	end)
end

return M
