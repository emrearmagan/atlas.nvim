local M = {}

local mapper = require("atlas.issues.providers.shortcut.api.mapper")
local service = require("atlas.issues.providers.shortcut.api.service")

---@param on_done fun(user: IssueUser|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_current(on_done)
	local cached, found = service.get_cache("user")
	if found then
		on_done(cached, nil)
		return nil
	end

	return service.request("GET", "/member", nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		---@cast result table
		local user = mapper.to_user(result)
		service.set_cache("user", user)
		on_done(user, nil)
	end, { action = "Fetch Shortcut member" })
end

---@param on_done fun(users: IssueUser[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list(on_done)
	local cached, found = service.get_memory_cache("users")
	if found then
		on_done(cached, nil)
		return nil
	end

	return service.request("GET", "/members", nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		---@cast result table
		local users = {}
		for _, member in ipairs(result) do
			table.insert(users, mapper.to_user(member))
		end
		service.set_memory_cache("users", users)
		on_done(users, nil)
	end, { action = "Fetch Shortcut members" })
end

return M
