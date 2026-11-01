local M = {
	-- list_members = nil,
	-- get_assignable_users = nil,
}
---@cast M AtlasUsersCapability

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

return M
