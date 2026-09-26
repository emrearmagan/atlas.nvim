local service = require("atlas.providers.jira.client")
local config = require("atlas.config")
local json = require("atlas.core.json")

local M = {}

---@param raw_user any Decoded API value.
---@return AtlasUser|nil
function M.to_user(raw_user)
	raw_user = json.nilify(raw_user)
	if type(raw_user) ~= "table" then
		return nil
	end

	return {
		id = json.safe_str(raw_user[service.is_server() and "name" or "accountId"]) or "",
		name = json.safe_str(raw_user.displayName) or "",
		username = json.safe_str(raw_user.name),
	}
end

---@param callback fun(user: AtlasUser|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_user(callback)
	local jira = config.provider_options("jira") or {}
	local cache_key = string.format("jira:user:me:v2:%s:%s", tostring(jira.base_url or ""), tostring(jira.email or ""))
	local cached = service.get_cache(cache_key)
	if cached then
		callback(cached, nil)
		return nil
	end

	return service.request("GET", "/myself", nil, function(result, err)
		if err or not result then
			callback(nil, err or "Empty response")
			return
		end

		local user = M.to_user(result)

		service.set_cache(cache_key, user)
		callback(user, nil)
	end, {
		action = "Fetch current user",
	})
end

return M
