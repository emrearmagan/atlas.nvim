local http = require("atlas.core.http")
local cache = require("atlas.core.cache")
local logger = require("atlas.core.logger")
local memory_cache = require("atlas.core.memory_cache")
local config = require("atlas.config")

local API_PATH = "/api/v1"
local M = {}

---@param provider_id ForgeProviderId
---@return ForgeClient
function M.new(provider_id)
	local provider_name = provider_id == "gitea" and "Gitea" or "Forgejo"
	local client = {}

	---@return AtlasGiteaConfig|AtlasForgejoConfig
	function client.config()
		return config.provider_options(provider_id) or {}
	end

	---@return string, string|nil
	function client.get_auth()
		local cfg = client.config()
		local base_url = vim.trim(cfg.base_url or "")
		local token = vim.trim(cfg.token or "")
		if base_url == "" or token == "" then
			return "", string.format("Missing %s base_url or token in config", provider_name)
		end
		return base_url:gsub("/+$", ""), nil
	end

	---@return string
	function client.base_url()
		return vim.trim(client.config().base_url or ""):gsub("/+$", "")
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

	function client.clear_cache(prefix)
		cache.clear_prefix(prefix)
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

	---@param values table<string, ForgeQueryValue>
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
	---@param on_done fun(result: any, err: string|nil, status?: integer)
	---@param ctx ForgeRequestContext|nil
	---@return ForgeRequestHandle|nil
	function client.request(method, endpoint, data, on_done, ctx)
		local _, auth_err = client.get_auth()
		if auth_err then
			logger.logerror(provider_name .. " auth missing", { error = auth_err })
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

		local log = vim.tbl_extend("keep", {
			provider = provider_id,
			endpoint = endpoint,
			method = method,
		}, ctx or {})
		local message = log.action or string.format("%s %s %s", provider_name, method, endpoint)
		log.action = nil
		logger.loginfo(message, log)
		return http.curl_request(method, client.url(endpoint), client.headers(), payload, function(result, err, status)
			if err then
				logger.logerror(message .. " failed", vim.tbl_extend("force", {}, log, { error = err }))
				on_done(nil, err, status)
				return
			end
			on_done(result, nil, status)
		end)
	end

	---@param method string
	---@param endpoint string
	---@param on_done fun(result: string|nil, err: string|nil, status?: integer)
	---@param ctx ForgeRequestContext|nil
	---@return ForgeRequestHandle|nil
	function client.request_text(method, endpoint, on_done, ctx)
		local _, auth_err = client.get_auth()
		if auth_err then
			logger.logerror(provider_name .. " auth missing", { error = auth_err })
			vim.schedule(function()
				on_done(nil, auth_err)
			end)
			return nil
		end

		method = method:upper()
		local log = vim.tbl_extend("keep", {
			provider = provider_id,
			endpoint = endpoint,
			method = method,
		}, ctx or {})
		local message = log.action or string.format("%s %s %s", provider_name, method, endpoint)
		log.action = nil
		logger.loginfo(message, log)
		return http.curl_text_request(method, client.url(endpoint), client.headers(), nil, function(result, err, status)
			if err then
				logger.logerror(message .. " failed", vim.tbl_extend("force", {}, log, { error = err }))
				on_done(nil, err, status)
				return
			end
			on_done(result, nil, status)
		end)
	end

	return client
end

return M
