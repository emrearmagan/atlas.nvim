local M = {}

local pulls_cli = require("atlas.pulls.providers.github.api.cli")
local cache = require("atlas.core.cache")

local DEFAULT_CACHE_TTL = 300

---@return AtlasGitHubIssuesConfig
function M.github_config()
	local config = require("atlas.config")
	return ((config.options.issues or {}).providers or {}).github or {}
end

---@return number
function M.cache_ttl()
	return tonumber(M.github_config().cache_ttl) or DEFAULT_CACHE_TTL
end

---@param key string
---@return any|nil, boolean
function M.get_cache(key)
	local entry = cache.get(key)
	if entry and entry.value ~= nil then
		return entry.value, true
	end
	return nil, false
end

---@param key string
---@param value any
---@param ttl number|nil
function M.set_cache(key, value, ttl)
	cache.set(key, value, ttl or M.cache_ttl())
end

---@param key string
function M.delete_cache(key)
	cache.delete(key)
end

M.gh = pulls_cli.gh
M.gh_json = pulls_cli.gh_json
M.api = pulls_cli.api

return M
