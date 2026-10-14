local M = {}

local config = require("atlas.config")
local http = require("atlas.core.http")
local memory_cache = require("atlas.core.memory_cache")
local cache = require("atlas.core.cache")
local logger = require("atlas.core.logger")

local API_BASE_URL = "https://api.app.shortcut.com/api/v3"
local CACHE_PREFIX = "shortcut:"

---@return AtlasShortcutConfig
local function shortcut_config()
	return config.provider_options("shortcut") or {}
end

---@return string|nil
local function auth_error()
	local token = shortcut_config().token
	if not token or token == "" then
		return "Missing Shortcut token in config (providers.shortcut.token)"
	end
end

---@return table<string, string>
local function build_headers()
	return {
		["Shortcut-Token"] = shortcut_config().token,
		["Content-Type"] = "application/json",
		Accept = "application/json",
	}
end

---@return number
local function cache_ttl()
	return tonumber(shortcut_config().cache_ttl) or 300
end

---@param key string
---@return string
local function cache_key(key)
	local token = tostring(shortcut_config().token or "")
	return CACHE_PREFIX .. vim.fn.sha256(token) .. ":" .. key
end

---@param key string
---@return any|nil, boolean
function M.get_memory_cache(key)
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
function M.set_memory_cache(key, value, ttl)
	if cache_ttl() > 0 then
		memory_cache.set(cache_key(key), value, ttl or cache_ttl())
	end
end

---@param key string
---@return any|nil, boolean
function M.get_cache(key)
	if cache_ttl() <= 0 then
		return nil, false
	end
	local entry = cache.get(cache_key(key))
	if not entry then
		return nil, false
	end
	return entry.value, true
end

---@param key string
---@param value any
---@param ttl? number
function M.set_cache(key, value, ttl)
	if cache_ttl() > 0 then
		cache.set(cache_key(key), value, ttl or cache_ttl())
	end
end

---@param prefix? string
function M.clear_cache(prefix)
	local namespaced = cache_key(prefix or "")
	memory_cache.clear_prefix(namespaced)
	cache.clear_prefix(namespaced)
end

---@class ShortcutRequestContext
---@field action string|nil
---@field issue_key string|nil

---@alias ShortcutHttpMethod "GET"|"POST"|"PUT"|"DELETE"

---@param method ShortcutHttpMethod
---@param endpoint string
---@param data table|nil
---@param on_done fun(result: table|nil, err: string|nil)
---@param ctx? ShortcutRequestContext
---@return { job_id: integer, cancel: fun() }|nil
function M.request(method, endpoint, data, on_done, ctx)
	local auth_err = auth_error()
	if auth_err then
		logger.logerror("Shortcut auth missing", { error = auth_err })
		on_done(nil, auth_err)
		return nil
	end

	local payload
	if data then
		local ok, encoded = pcall(vim.json.encode, data)
		if not ok then
			on_done(nil, "Request payload is invalid")
			return nil
		end
		payload = encoded
	end

	ctx = ctx or {}
	local log = vim.tbl_extend("keep", { method = method, endpoint = endpoint }, ctx)
	local message = log.action or "Shortcut request"
	log.action = nil
	logger.loginfo(message, log)

	return http.curl_request(method, API_BASE_URL .. endpoint, build_headers(), payload, function(result, err)
		if err then
			logger.logerror(message .. " failed", vim.tbl_extend("force", {}, log, { error = tostring(err) }))
			on_done(nil, err)
			return
		end

		if type(result) ~= "table" then
			on_done(nil, "Shortcut response is not a JSON object or array")
			return
		end
		on_done(result, nil)
	end)
end

return M
