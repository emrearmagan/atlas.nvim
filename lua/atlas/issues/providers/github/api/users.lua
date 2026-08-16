local M = {}

local cli = require("atlas.providers.github.client").issues
local normalizer = require("atlas.issues.providers.github.api.mapper")

---@param on_done fun(user: IssueUser|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_user(on_done)
	local cache_key = "github_issues:myself"
	local cached, ok = cli.get_cache(cache_key)
	if ok then
		on_done(cached, nil)
		return nil
	end

	return cli.gh({ "api", "user" }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		local user = normalizer.to_user(result)
		if user then
			cli.set_cache(cache_key, user)
		end
		on_done(user, nil)
	end, {
		action = "Issues fetch user",
	})
end

return M
