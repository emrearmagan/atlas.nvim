local M = {}

local users = require("atlas.pulls.providers.azure.api.users")

---@param on_done fun(user: IssueUser|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_user(on_done)
	return users.fetch_user(function(user, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done({ account_id = user.id, display_name = user.name, username = user.username }, nil)
	end)
end

return M
