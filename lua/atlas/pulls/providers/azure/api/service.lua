-- https://learn.microsoft.com/en-us/rest/api/azure/devops/?view=azure-devops-rest-7.1

local M = {}

local config = require("atlas.config")
local http = require("atlas.core.http")
local memory_cache = require("atlas.core.memory_cache")
local cache = require("atlas.core.cache")
local logger = require("atlas.core.logger")
local utils = require("atlas.core.utils")

local function azure_config()
	return config.provider_options("azure") or {}
end

---@return string
function M.base_url()
	return (tostring(azure_config().base_url or ""):gsub("/+$", ""))
end

---@return number
local function cache_ttl()
	return tonumber(azure_config().cache_ttl) or 300
end

---@param key string
---@return string
local function cache_key(key)
	return "azure:" .. M.base_url():lower() .. ":" .. key
end

---@param key string
---@return any|nil, boolean
function M.get_cache(key)
	if cache_ttl() <= 0 then
		return nil, false
	end
	local entry = memory_cache.get(cache_key(key))
	if not entry then
		return nil, false
	end
	return entry.value, true
end

---@param key string
---@param value any
---@param ttl? number
function M.set_cache(key, value, ttl)
	if cache_ttl() <= 0 then
		return
	end
	memory_cache.set(cache_key(key), value, ttl or cache_ttl())
end

---@param key string
---@return any|nil, boolean
function M.get_persistent_cache(key)
	if cache_ttl() <= 0 then
		return nil, false
	end

	local entry = cache.get(cache_key(key))
	if not entry or entry.value == nil then
		return nil, false
	end
	return entry.value, true
end

---@param key string
---@param value any
---@param ttl? number
function M.set_persistent_cache(key, value, ttl)
	if cache_ttl() <= 0 then
		return
	end
	cache.set(cache_key(key), value, ttl or cache_ttl())
end

function M.clear_cache()
	memory_cache.clear_prefix("azure:")
	cache.clear_prefix("azure:")
end

M.url_encode = utils.url_encode

---@param params table<string, any>
---@return string
function M.build_query(params)
	local parts = {}
	for key, value in pairs(params) do
		table.insert(parts, key .. "=" .. M.url_encode(tostring(value)))
	end
	table.sort(parts)
	return "?" .. table.concat(parts, "&")
end

---@param method string
---@param endpoint string
---@param data? table
---@param on_done fun(result: any, err: string|nil, headers?: table<string, string>)
---@param ctx? table
---@param api_version? string
---@return { job_id: integer, cancel: fun() }|nil
function M.request(method, endpoint, data, on_done, ctx, api_version)
	local cfg = azure_config()
	if not cfg.base_url or cfg.base_url == "" or not cfg.token or cfg.token == "" then
		local err = "Missing Azure DevOps credentials in config"
		logger.logerror("Azure DevOps auth missing", { error = err })
		on_done(nil, err)
		return nil
	end

	local payload = data and vim.fn.json_encode(data) or nil
	local separator = endpoint:find("?", 1, true) and "&" or "?"
	endpoint = endpoint .. separator .. "api-version=" .. (api_version or "7.1")

	local headers = {
		Authorization = "Basic " .. vim.base64.encode(":" .. cfg.token),
		["Content-Type"] = "application/json",
		Accept = "application/json",
	}
	local log = vim.tbl_extend("keep", { method = method, endpoint = endpoint }, ctx or {})
	local message = log.action or "Azure DevOps request"
	log.action = nil
	logger.loginfo(message, log)

	return http.curl_request(method, M.base_url() .. endpoint, headers, payload, function(result, err, response_headers)
		if err then
			logger.logerror(message .. " failed", vim.tbl_extend("force", {}, log, { error = tostring(err) }))
			on_done(nil, err)
			return
		end
		on_done(result, nil, response_headers)
	end)
end

return M
