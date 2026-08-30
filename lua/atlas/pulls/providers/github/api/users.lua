local M = {}

local cli = require("atlas.providers.github.client")
local mapper = require("atlas.pulls.providers.github.api.mapper")

---@param on_done fun(user: PullsUser|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_user(on_done)
	local cache_key = "github:user:me"

	local cached, ok = cli.get_cache(cache_key)
	if ok then
		on_done(cached, nil)
		return nil
	end

	return cli.gh({ "api", "user" }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch user")
			return
		end

		local user = mapper.to_user(result)
		cli.set_cache(cache_key, user)
		on_done(user, nil)
	end, {
		action = "Fetch current user",
	})
end

return M
