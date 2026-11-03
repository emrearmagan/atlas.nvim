local json = require("atlas.core.json")

local M = {}

---@param raw any
---@return AtlasUser|nil
function M.to_user(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local login = json.safe_str(raw.login)
	if not login or login == "" then
		return nil
	end
	local name = json.safe_str(raw.full_name)
	return { id = json.safe_str(raw.id), username = login, name = name and name ~= "" and name or login }
end

---@param service ForgeService
---@return AtlasUsersCapability
function M.new(service)
	local users = {}

	function users.fetch_user(on_done)
		local key = service.id .. ":" .. service.base_url() .. ":current_user"
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(M.to_user(cached), nil)
			return nil
		end
		return service.request("GET", "/user", nil, function(raw, err)
			if err then
				on_done(nil, err)
				return
			end
			service.set_cache(key, raw)
			on_done(M.to_user(raw), nil)
		end, { action = "Fetch current user" })
	end

	function users.get_assignable_users(slug, query, on_done)
		local owner, repo = tostring(slug or ""):match("^([^/]+)/([^/]+)$")
		if not owner then
			on_done(nil, "Invalid " .. service.name .. " repository")
			return nil
		end
		local endpoint = string.format("/repos/%s/%s/assignees", service.url_encode(owner), service.url_encode(repo))
		return service.request("GET", endpoint, nil, function(raw, err)
			if err then
				on_done(nil, err)
				return
			end
			local result = {}
			local term = vim.trim(query or ""):lower()
			for _, value in ipairs(raw) do
				local user = M.to_user(value)
				if user and (term == "" or (user.username .. " " .. user.name):lower():find(term, 1, true)) then
					table.insert(result, user)
				end
			end
			on_done(result, nil)
		end, { action = "Fetch assignable users", repo = slug })
	end

	return users
end

return M
