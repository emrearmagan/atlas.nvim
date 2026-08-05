local M = {}

local config = require("atlas.config")
local logger = require("atlas.core.logger")
local http = require("atlas.core.http")
local memory_cache = require("atlas.core.memory_cache")

local CLOUD_BASE = "https://api.bitbucket.org/2.0"
local SERVER_API_PATH = "/rest/api/1.0"

---@return AtlasBitbucketConfig
local function bb_config()
	return (((config.options or {}).pulls or {}).providers or {}).bitbucket or {} ---@type AtlasBitbucketConfig
end

---@param err any
---@return string
local function sanitize_error(err)
	return (tostring(err or ""):gsub("[\r\n]+", " | "))
end

---@return "cloud"|"server"
function M.api_type()
	return bb_config().api_type == "server" and "server" or "cloud"
end

---@return string, string, string|nil
function M.get_auth()
	local bb = bb_config()
	local user = tostring(bb.user or "")
	local token = tostring(bb.token or "")

	if not user or user == "" or not token or token == "" then
		return "", "", "Missing Bitbucket credentials in config (bitbucket.user / bitbucket.token)"
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

---@return string
function M.base_url()
	if M.api_type() == "server" then
		local cfg_base = tostring(bb_config().base_url or "")
		return cfg_base:gsub("/+$", "") .. SERVER_API_PATH
	end
	return CLOUD_BASE
end

---@param endpoint string
---@return string
function M.url(endpoint)
	if endpoint:sub(1, 1) ~= "/" then
		endpoint = "/" .. endpoint
	end
	return M.base_url() .. endpoint
end

---@param api_path string  e.g. "/rest/build-status/1.0"
---@param endpoint string  e.g. "/commits/<sha>"
---@return string
function M.server_url(api_path, endpoint)
	local cfg_base = tostring(bb_config().base_url or ""):gsub("/+$", "")
	if endpoint:sub(1, 1) ~= "/" then
		endpoint = "/" .. endpoint
	end
	return cfg_base .. api_path .. endpoint
end

---Normalize a Bitbucket Server clone path to PROJECT/repository.
---HTTPS clone URLs may include the configured context path and an /scm prefix.
---@param slug string|nil
---@return string
function M.normalize_server_repo_slug(slug)
	local result = tostring(slug or ""):gsub("^/+", ""):gsub("%.git$", "")
	local base_path = tostring(bb_config().base_url or ""):match("^https?://[^/]+(/[^?#]*)") or ""
	base_path = base_path:gsub("^/+", ""):gsub("/+$", "")
	if base_path ~= "" and result:sub(1, #base_path + 1) == base_path .. "/" then
		result = result:sub(#base_path + 2)
	end
	return (result:gsub("^[Ss][Cc][Mm]/", ""))
end

---@return number
function M.cache_ttl()
	return tonumber(bb_config().cache_ttl) or 300
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
	if type(result) ~= "table" then
		return nil
	end

	-- Cloud: { error = { message = "..." } } or { error = "..." }
	if result.error ~= nil then
		if type(result.error) == "table" and result.error.message then
			return tostring(result.error.message)
		end
		if type(result.error) == "string" then
			return result.error
		end
		return "Bitbucket API error"
	end

	-- Server: { errors = [{ message, exceptionName, ... }] }
	if type(result.errors) == "table" and #result.errors > 0 then
		local parts = {}
		for _, e in ipairs(result.errors) do
			if type(e) == "table" and e.message then
				table.insert(parts, tostring(e.message))
			end
		end
		if #parts > 0 then
			return table.concat(parts, " | ")
		end
		return "Bitbucket API error"
	end
	return nil
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
		callback(nil, sanitize_error(auth_err))
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
