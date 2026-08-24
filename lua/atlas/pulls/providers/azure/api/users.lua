local M = {}

local service = require("atlas.pulls.providers.azure.api.service")

---@param on_done fun(user: PullsUser|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_user(on_done)
	local cache_key = "user:me"
	local cached, ok = service.get_persistent_cache(cache_key)
	if ok then
		on_done(cached, nil)
		return nil
	end

	return service.request("GET", "/_apis/ConnectionData", nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local identity = result.authenticatedUser
		---@type PullsUser
		local user = {
			name = identity.providerDisplayName,
			id = identity.id,
			username = identity.properties.Account["$value"],
		}
		service.set_persistent_cache(cache_key, user)
		on_done(user, nil)
	end, { action = "Fetch current user" }, "7.1-preview.1")
end

return M
