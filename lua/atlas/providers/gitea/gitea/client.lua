local http = require("atlas.core.http")
local cache = require("atlas.core.cache")
local logger = require("atlas.core.logger")
local memory_cache = require("atlas.core.memory_cache")
local config = require("atlas.config")

local API_PATH = "/api/v1"
local API_TYPE = "gitea"
local NAME = "Gitea"

---@param domain "pulls"|"issues"
---@return table
local function new(domain)
	local client = {}

	---@return AtlasGiteaForgejoProviderConfig
	function client.config()
		return config.provider_options("gitea") or {}
	end

	---@return string
	function client.api_type()
		return API_TYPE
	end

	---@return string, string|nil
	function client.get_auth()
		local cfg = client.config()
		local base_url = vim.trim(cfg.base_url or "")
		local token = vim.trim(cfg.token or "")
		if base_url == "" or token == "" then
			return "", "Missing Gitea base_url or token in config"
		end
		return base_url:gsub("/+$", ""), nil
	end

	---@return string
	function client.base_url()
		return (client.config().base_url or ""):gsub("/+$", "")
	end

	function client.cache_ttl()
		return client.config().cache_ttl or 300
	end

	function client.get_cache(key)
		local entry = cache.get(key)
		return entry and entry.value or nil, entry ~= nil and entry.value ~= nil
	end

	function client.set_cache(key, value)
		cache.set(key, value, client.cache_ttl())
	end

	function client.get_memory_cache(key)
		local entry = memory_cache.get(key)
		return entry and entry.value or nil, entry ~= nil and entry.value ~= nil
	end

	function client.set_memory_cache(key, value)
		memory_cache.set(key, value, client.cache_ttl())
	end

	function client.delete_memory_cache(key)
		memory_cache.delete(key)
	end

	---@param value string|nil
	---@return string|nil
	function client.absolute_url(value)
		local url = value or ""
		if url == "" then
			return nil
		end
		if url:sub(1, 1) ~= "/" then
			return url
		end
		local base = client.base_url()
		local origin, prefix = base:match("^([%a][%w+.-]*://[^/]+)(/.*)$")
		if not origin then
			return base .. url
		end
		prefix = prefix:gsub("/+$", "")
		if url == prefix or url:sub(1, #prefix + 1) == prefix .. "/" then
			return origin .. url
		end
		return base .. url
	end

	---@param endpoint string
	---@return string
	function client.url(endpoint)
		return client.base_url() .. API_PATH .. endpoint
	end

	---@param value string
	---@return string
	function client.url_encode(value)
		return (value:gsub("([^%w%-_.~])", function(char)
			return string.format("%%%02X", string.byte(char))
		end))
	end

	---@param values table<string, string|number|boolean|(string|number|boolean)[]|nil>
	---@return string
	function client.query(values)
		local keys = vim.tbl_keys(values)
		table.sort(keys)
		local parts = {}
		local function add(key, value)
			if value ~= nil and value ~= "" then
				table.insert(parts, client.url_encode(key) .. "=" .. client.url_encode(tostring(value)))
			end
		end
		for _, key in ipairs(keys) do
			local value = values[key]
			if type(value) == "table" then
				for _, item in ipairs(value) do
					add(key, item)
				end
			else
				add(key, value)
			end
		end
		return #parts > 0 and ("?" .. table.concat(parts, "&")) or ""
	end

	---@return table<string, string>
	function client.headers()
		return {
			Accept = "application/json",
			["Content-Type"] = "application/json",
			Authorization = "token " .. vim.trim(client.config().token or ""),
		}
	end

	---@param method string
	---@param endpoint string
	---@param data table|nil
	---@param on_done fun(result: any, err: string|nil)
	---@return { job_id: integer, cancel: fun() }|nil
	function client.request(method, endpoint, data, on_done)
		local _, auth_err = client.get_auth()
		if auth_err then
			logger.logerror(NAME .. " auth missing", { domain = domain, error = auth_err })
			vim.schedule(function()
				on_done(nil, auth_err)
			end)
			return nil
		end

		method = method:upper()
		local payload
		if data ~= nil then
			payload = vim.json.encode(data)
		end

		logger.loginfo(NAME .. " request", {
			api_type = API_TYPE,
			domain = domain,
			endpoint = endpoint,
			method = method,
		})
		return http.curl_request(method, client.url(endpoint), client.headers(), payload, function(result, err)
			if err then
				logger.logerror(NAME .. " request failed", {
					domain = domain,
					endpoint = endpoint,
					method = method,
					error = err,
				})
				on_done(nil, err)
				return
			end
			on_done(result, nil)
		end)
	end

	---@param method string
	---@param endpoint string
	---@param on_done fun(result: string|nil, err: string|nil)
	---@return { job_id: integer, cancel: fun() }|nil
	function client.request_text(method, endpoint, on_done)
		local _, auth_err = client.get_auth()
		if auth_err then
			logger.logerror(NAME .. " auth missing", { domain = domain, error = auth_err })
			vim.schedule(function()
				on_done(nil, auth_err)
			end)
			return nil
		end

		method = method:upper()
		logger.loginfo(NAME .. " request", {
			api_type = API_TYPE,
			domain = domain,
			endpoint = endpoint,
			method = method,
		})
		return http.curl_text_request(method, client.url(endpoint), client.headers(), nil, function(result, err)
			if err then
				logger.logerror(NAME .. " request failed", {
					domain = domain,
					endpoint = endpoint,
					method = method,
					error = err,
				})
				on_done(nil, err)
				return
			end
			on_done(result, nil)
		end)
	end

	return client
end

return {
	pulls = new("pulls"),
	issues = new("issues"),
}
