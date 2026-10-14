local M = {
	-- list_members = nil,
	-- get_assignable_users = nil,
}

local json = require("atlas.core.json")
local service = require("atlas.providers.shortcut.client")

---@class ShortcutUser : AtlasUser
---@field id string
---@field disabled boolean

---@param raw table
---@return ShortcutUser
function M.to_user(raw)
	local profile = json.safe_table(raw.profile)
	local id = tostring(raw.id)
	local username = json.safe_str(profile.mention_name) or json.safe_str(raw.mention_name)
	local name = json.safe_str(profile.name) or json.safe_str(raw.name) or username or id
	return { id = id, name = name, username = username, disabled = raw.disabled == true }
end

---@param on_done fun(user: AtlasUser|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_user(on_done)
	local cached, found = service.get_cache("user:v2")
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
		local user = M.to_user(result)
		service.set_cache("user:v2", user)
		on_done(user, nil)
	end, { action = "Fetch Shortcut member" })
end

---@param on_done fun(users: ShortcutUser[]|nil, err: string|nil)
---@param opts? { force_refresh?: boolean }
---@return { cancel: fun() }|nil
function M.list(on_done, opts)
	if not (opts and opts.force_refresh) then
		local cached, found = service.get_memory_cache("users")
		if found then
			on_done(cached, nil)
			return nil
		end
	end

	return service.request("GET", "/members", nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		---@cast result table
		local users = {}
		for _, member in ipairs(result) do
			table.insert(users, M.to_user(member))
		end
		service.set_memory_cache("users", users)
		on_done(users, nil)
	end, { action = "Fetch Shortcut members" })
end

return M
