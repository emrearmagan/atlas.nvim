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

---@return string|nil token, string|nil err
function M.get_auth()
	local token = shortcut_config().token
	if not token or token == "" then
		return nil, "Missing Shortcut token in config (providers.shortcut.token)"
	end
	return token, nil
end

---@return table<string, string>
function M.build_headers()
	return {
		["Shortcut-Token"] = shortcut_config().token,
		["Content-Type"] = "application/json",
		Accept = "application/json",
	}
end

---@param endpoint string
---@return string
function M.url(endpoint)
	return API_BASE_URL .. endpoint
end

---@param value string
---@return string
function M.url_encode(value)
	return (value:gsub("([^%w%-_.~])", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

---@return number
function M.cache_ttl()
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
	if M.cache_ttl() <= 0 then
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
	if M.cache_ttl() > 0 then
		memory_cache.set(cache_key(key), value, ttl or M.cache_ttl())
	end
end

---@param key string
---@return any|nil, boolean
function M.get_cache(key)
	if M.cache_ttl() <= 0 then
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
	if M.cache_ttl() > 0 then
		cache.set(cache_key(key), value, ttl or M.cache_ttl())
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
	local _, auth_error = M.get_auth()
	if auth_error then
		logger.logerror("Shortcut auth missing", { error = auth_error })
		on_done(nil, auth_error)
		return nil
	end

	local payload
	if data then
		payload = vim.json.encode(data)
	end

	ctx = ctx or {}
	local log = vim.tbl_extend("keep", { method = method, endpoint = endpoint }, ctx)
	local message = log.action or "Shortcut request"
	log.action = nil
	logger.loginfo(message, log)

	return http.curl_request(method, M.url(endpoint), M.build_headers(), payload, function(result, err)
		if err then
			logger.logerror(message .. " failed", vim.tbl_extend("force", {}, log, { error = tostring(err) }))
			on_done(nil, err)
			return
		end

		result.__http_status = nil
		on_done(result, nil)
	end)
end

return M
