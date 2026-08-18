local M = {}

local config = require("atlas.config")
local http = require("atlas.core.http")
local memory_cache = require("atlas.core.memory_cache")
local cache = require("atlas.core.cache")
local logger = require("atlas.core.logger")

local API_PATH = "/api/v4"

---@param value any
---@return string|nil
local function error_message(value)
	if value == nil or value == vim.NIL then
		return nil
	end
	if type(value) == "string" then
		return value
	end
	if type(value) == "table" then
		local parts = {}
		for key, messages in pairs(value) do
			if type(messages) == "table" then
				for _, message in ipairs(messages) do
					table.insert(parts, tostring(key) .. ": " .. tostring(message))
				end
			else
				table.insert(parts, tostring(key) .. ": " .. tostring(messages))
			end
		end
		if #parts > 0 then
			return table.concat(parts, "; ")
		end
	end
	return nil
end

---@param default_message string
---@param fields table
---@param ctx? table
local function log_request(default_message, fields, ctx)
	local log = vim.tbl_extend("keep", fields, ctx or {})
	local message = log.action or default_message
	log.action = nil
	logger.loginfo(message, log)
	return message, log
end

---@param domain "pulls"|"issues"
---@return table
local function new(domain)
	local client = {}

	function client.gitlab_config()
		local options = config.options or {}
		local provider_options = (options[domain] or {}).providers or {}
		return provider_options.gitlab or {}
	end

	---@return string base_url, string|nil err
	function client.get_auth()
		local cfg = client.gitlab_config()
		local base_url = cfg.base_url
		local token = cfg.token
		if not base_url or base_url == "" or not token or token == "" then
			return "", "Missing GitLab credentials in config"
		end
		return base_url, nil
	end

	---@return string
	function client.base_url()
		local raw = tostring(client.gitlab_config().base_url or "")
		return (raw:gsub("/+$", ""))
	end

	---@param endpoint string
	---@return string
	function client.url(endpoint)
		return client.base_url() .. API_PATH .. endpoint
	end

	---@return table<string, string>
	function client.build_headers()
		return {
			["PRIVATE-TOKEN"] = tostring(client.gitlab_config().token or ""),
			["Content-Type"] = "application/json",
			Accept = "application/json",
		}
	end

	---@return number
	function client.cache_ttl()
		return tonumber(client.gitlab_config().cache_ttl) or 300
	end

	---@param key string
	---@return any|nil, boolean
	function client.get_memory_cache(key)
		local entry = memory_cache.get(key)
		if not entry then
			return nil, false
		end
		return entry.value, true
	end

	---@param key string
	---@param value any
	---@param ttl? number
	function client.set_memory_cache(key, value, ttl)
		memory_cache.set(key, value, ttl or client.cache_ttl())
	end

	---@param key string
	function client.delete_memory_cache(key)
		memory_cache.delete(key)
	end

	---@param key string
	---@return any|nil, boolean
	function client.get_cache(key)
		local entry = cache.get(key)
		if entry and entry.value ~= nil then
			return entry.value, true
		end
		return nil, false
	end

	---@param key string
	---@param value any
	---@param ttl? number
	function client.set_cache(key, value, ttl)
		cache.set(key, value, ttl or client.cache_ttl())
	end

	---@param key string
	function client.delete_cache(key)
		cache.delete(key)
	end

	---@param prefix string
	function client.clear_cache(prefix)
		cache.clear_prefix(prefix)
	end

	---@param str string
	---@return string
	function client.url_encode(str)
		return (str:gsub("([^%w%-_.~])", function(char)
			return string.format("%%%02X", string.byte(char))
		end))
	end

	---@param method string
	---@param endpoint string
	---@param data? table
	---@param on_done fun(result: any, err: string|nil)
	---@param ctx? table
	---@return { job_id: integer, cancel: fun() }|nil
	function client.request(method, endpoint, data, on_done, ctx)
		local _, auth_err = client.get_auth()
		if auth_err then
			logger.logerror("GitLab auth missing", { error = auth_err })
			on_done(nil, auth_err)
			return nil
		end

		local payload
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

		local message, log = log_request("GitLab request", { method = method, endpoint = endpoint }, ctx)
		return http.curl_request(method, client.url(endpoint), client.build_headers(), payload, function(result, err)
			if err then
				logger.logerror(message .. " failed", vim.tbl_extend("force", {}, log, { error = tostring(err) }))
				on_done(nil, err)
				return
			end

			if type(result) == "table" and not vim.islist(result) then
				local api_err = error_message(result.message) or error_message(result.error_description)
				if api_err == nil and result.error ~= nil and result.error ~= vim.NIL then
					api_err = tostring(result.error)
				end
				if api_err ~= nil then
					logger.logerror(message .. " failed", vim.tbl_extend("force", {}, log, { error = api_err }))
					on_done(nil, api_err)
					return
				end
			end

			on_done(result, nil)
		end)
	end

	---@param method string
	---@param endpoint string
	---@param on_done fun(result: string|nil, err: string|nil)
	---@param ctx? table
	---@return { job_id: integer, cancel: fun() }|nil
	function client.request_text(method, endpoint, on_done, ctx)
		local _, auth_err = client.get_auth()
		if auth_err then
			logger.logerror("GitLab auth missing", { error = auth_err })
			on_done(nil, auth_err)
			return nil
		end

		local message, log = log_request("GitLab request", { method = method, endpoint = endpoint }, ctx)
		return http.curl_text_request(method, client.url(endpoint), client.build_headers(), nil, function(result, err)
			if err then
				logger.logerror(message .. " failed", vim.tbl_extend("force", {}, log, { error = tostring(err) }))
				on_done(nil, err)
				return
			end
			on_done(result, nil)
		end)
	end

	---@param query string
	---@param variables? table
	---@param on_done fun(result: any, err: string|nil)
	---@param ctx? table
	---@return { job_id: integer, cancel: fun() }|nil
	function client.graphql(query, variables, on_done, ctx)
		local _, auth_err = client.get_auth()
		if auth_err then
			logger.logerror("GitLab auth missing", { error = auth_err })
			on_done(nil, auth_err)
			return nil
		end

		local payload = vim.fn.json_encode({ query = query, variables = variables or vim.empty_dict() })
		local message, log = log_request("GitLab GraphQL", { transport = "graphql" }, ctx)
		return http.curl_request(
			"POST",
			client.base_url() .. "/api/graphql",
			client.build_headers(),
			payload,
			function(result, err)
				if err then
					logger.logerror(message .. " failed", vim.tbl_extend("force", {}, log, { error = tostring(err) }))
					on_done(nil, err)
					return
				end
				if type(result) == "table" and type(result.errors) == "table" and #result.errors > 0 then
					local graphql_err = tostring(result.errors[1].message or "GraphQL error")
					logger.logerror(message .. " failed", vim.tbl_extend("force", {}, log, { error = graphql_err }))
					on_done(nil, graphql_err)
					return
				end
				on_done(type(result) == "table" and result.data or nil, nil)
			end
		)
	end

	---@param endpoint string
	---@param on_done fun(result: table[]|nil, err: string|nil)
	---@return { cancel: fun() }
	function client.fetch_all_pages(endpoint, on_done)
		local values = {}
		local current
		local cancelled = false
		local page = 1
		if not endpoint:find("[?&]per_page=") then
			local separator = endpoint:find("?", 1, true) and "&" or "?"
			endpoint = endpoint .. separator .. "per_page=100"
		end
		local separator = endpoint:find("?", 1, true) and "&" or "?"

		local function fetch_page()
			if cancelled then
				return
			end
			current = client.request(
				"GET",
				string.format("%s%spage=%d", endpoint, separator, page),
				nil,
				function(result, err)
					if cancelled then
						return
					end
					if err or type(result) ~= "table" then
						on_done(nil, err or "Invalid paginated response")
						return
					end
					vim.list_extend(values, result)
					if #result < 100 then
						on_done(values, nil)
						return
					end
					page = page + 1
					fetch_page()
				end
			)
		end

		fetch_page()
		return {
			cancel = function()
				cancelled = true
				if current then
					current.cancel()
				end
			end,
		}
	end

	return client
end

M.issues = new("issues")
M.pulls = new("pulls")

return M
