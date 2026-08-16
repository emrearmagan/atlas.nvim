local M = {}

local service = require("atlas.pulls.providers.bitbucket.api.service")
local cache = require("atlas.core.cache")
local memory_cache = require("atlas.core.memory_cache")
local logger = require("atlas.core.logger")

---@param on_done fun(user: PullsUser|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_current_user(on_done)
	local user_slug, _, auth_err = service.get_auth()
	if auth_err then
		on_done(nil, auth_err)
		return nil
	end

	local cachekey = string.format("bitbucket-server:user_profile:%s", user_slug)
	local cached = cache.get(cachekey)
	if cached and cached.value then
		logger.loginfo("Bitbucket Server current user cache hit", { user = user_slug })
		on_done(cached.value, nil)
		return nil
	end

	local endpoint = string.format("/users/%s", user_slug)
	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "No response from Bitbucket Server API")
			return
		end

		---@type PullsUser
		local current_user = {
			name = tostring(result.displayName or result.name or user_slug),
			id = tostring(result.id or ""),
			username = tostring(result.slug or result.name or user_slug),
		}

		logger.loginfo("Bitbucket Server current user fetch success", {
			display_name = current_user.name,
		})
		cache.set(cachekey, current_user, 86400)
		on_done(current_user, nil)
	end, {
		action = "Bitbucket Server current user fetch",
	})
end

---@param on_done fun(workspaces: BitbucketWorkspace[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_workspaces(on_done)
	local ttl = service.cache_ttl()
	local cache_key = "bitbucket-server:mem:projects"
	local cached = memory_cache.get(cache_key)
	if cached and cached.value then
		on_done(cached.value, nil)
		return nil
	end

	return service.request("GET", "/projects?limit=1000", nil, nil, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "No response from Bitbucket Server API")
			return
		end

		---@type BitbucketWorkspace[]
		local workspaces = {}
		for _, item in ipairs(result.values or {}) do
			local p = type(item) == "table" and item or {}
			local links = type(p.links) == "table" and p.links or {}
			local self_links = type(links.self) == "table" and links.self or {}
			local first_self = type(self_links[1]) == "table" and self_links[1] or {}
			table.insert(workspaces, {
				administrator = false,
				slug = tostring(p.key or ""),
				uuid = tostring(p.id or ""),
				links_self = first_self.href ~= nil and tostring(first_self.href) or nil,
			})
		end

		logger.loginfo("Bitbucket Server projects fetch success", { count = #workspaces })
		memory_cache.set(cache_key, workspaces, ttl)
		on_done(workspaces, nil)
	end, { action = "Bitbucket Server projects fetch" })
end

return M
