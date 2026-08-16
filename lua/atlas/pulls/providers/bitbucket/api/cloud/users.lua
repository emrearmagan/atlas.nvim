local M = {}

local service = require("atlas.pulls.providers.bitbucket.api.service")
local cache = require("atlas.core.cache")
local memory_cache = require("atlas.core.memory_cache")
local logger = require("atlas.core.logger")

---@param on_done fun(user: PullsUser|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_current_user(on_done)
	local user, _, auth_err = service.get_auth()
	if auth_err then
		on_done(nil, auth_err)
		return nil
	end

	local cachekey = string.format("bitbucket:user_profile:%s", user)
	local cached = cache.get(cachekey)
	if cached and cached.value then
		logger.loginfo("Bitbucket current user cache hit", { user = user })
		on_done(cached.value, nil)
		return nil
	end

	return service.request("GET", "/user", nil, nil, function(result, err)
		if err or not result then
			on_done(nil, err or "No response from Bitbucket API")
			return
		end

		local raw = type(result) == "table" and result or {}
		---@type PullsUser
		local current_user = {
			name = tostring(raw.display_name or raw.name or ""),
			id = tostring(raw.account_id or raw.uuid or ""),
			username = tostring(raw.nickname or raw.username or ""),
		}

		logger.loginfo("Bitbucket current user fetch success", {
			display_name = current_user.name,
		})
		cache.set(cachekey, current_user, 86400)
		on_done(current_user, nil)
	end, {
		action = "Bitbucket current user fetch",
	})
end

---@class BitbucketWorkspace
---@field administrator boolean
---@field slug string
---@field uuid string
---@field links_self string|nil

---@param on_done fun(workspaces: BitbucketWorkspace[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_workspaces(on_done)
	local ttl = service.cache_ttl()
	local workspace_cache_key = "bitbucket:mem:user_workspaces"
	local workspace_cached = memory_cache.get(workspace_cache_key)
	if workspace_cached and workspace_cached.value then
		logger.loginfo("Bitbucket workspace memory cache hit", {
			workspace_count = #(workspace_cached.value or {}),
		})
		on_done(workspace_cached.value, nil)
		return nil
	end

	return service.request("GET", "/user/workspaces", nil, nil, function(result, err)
		if err or not result then
			on_done(nil, err or "No response from Bitbucket API")
			return
		end

		local payload = type(result) == "table" and result or {}
		---@type BitbucketWorkspace[]
		local workspaces = {}
		for _, item in ipairs(payload.values or {}) do
			local entry = type(item) == "table" and item or {}
			local workspace = type(entry.workspace) == "table" and entry.workspace or {}
			local links = type(workspace.links) == "table" and workspace.links or {}
			local self_link = type(links.self) == "table" and links.self or {}

			table.insert(workspaces, {
				administrator = entry.administrator == true,
				slug = tostring(workspace.slug or ""),
				uuid = tostring(workspace.uuid or ""),
				links_self = self_link.href ~= nil and tostring(self_link.href) or nil,
			})
		end

		logger.loginfo("Bitbucket workspace fetch success", {
			workspace_count = #workspaces,
		})
		memory_cache.set(workspace_cache_key, workspaces, ttl)

		on_done(workspaces, nil)
	end, {
		action = "Bitbucket workspace fetch",
	})
end

return M
