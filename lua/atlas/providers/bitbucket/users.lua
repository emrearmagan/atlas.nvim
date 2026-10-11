local M = {
	-- list_members = nil,
	-- get_assignable_users = nil,
}

local service = require("atlas.providers.bitbucket.client")
local logger = require("atlas.core.logger")

---@param on_done fun(user: AtlasUser|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_user(on_done)
	local user, _, auth_err = service.get_auth()
	if auth_err then
		logger.logerror("Fetch current user failed", { error = auth_err })
		on_done(nil, auth_err)
		return nil
	end

	local cachekey = string.format("bitbucket:user_profile:%s", user)
	local cached = service.get_persistent_cache(cachekey)
	if cached then
		on_done(cached, nil)
		return nil
	end

	return service.request("GET", "/user", nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		---@type AtlasUser
		local current_user = {
			name = tostring(result.display_name or result.name or ""),
			id = tostring(result.account_id or result.uuid or ""),
			username = tostring(result.nickname or result.username or ""),
		}

		service.set_persistent_cache(cachekey, current_user, 86400)
		on_done(current_user, nil)
	end, { action = "Fetch current user", user = user })
end

---@class BitbucketWorkspace
---@field administrator boolean
---@field slug string
---@field uuid string
---@field links_self string|nil

---@param on_done fun(workspaces: BitbucketWorkspace[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_workspaces(on_done)
	local workspace_cache_key = "bitbucket:mem:user_workspaces"
	local workspace_cached = service.get_cache(workspace_cache_key)
	if workspace_cached then
		on_done(workspace_cached, nil)
		return nil
	end

	return service.request("GET", "/user/workspaces", nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		---@type BitbucketWorkspace[]
		local workspaces = {}
		for _, entry in ipairs(result.values or {}) do
			local workspace = entry.workspace

			table.insert(workspaces, {
				administrator = entry.administrator == true,
				slug = tostring(workspace.slug or ""),
				uuid = tostring(workspace.uuid or ""),
				links_self = tostring(workspace.links.self.href),
			})
		end

		service.set_cache(workspace_cache_key, workspaces)

		on_done(workspaces, nil)
	end, { action = "Fetch workspaces" })
end

return M
