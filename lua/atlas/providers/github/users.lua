local M = {}

local client = require("atlas.providers.github.client")
local mapping = require("atlas.providers.github.mapping")

---@param raw any
---@return AtlasUser|nil
function M.to_user(raw)
	local user = mapping.identity(raw)
	if not user or user.login == "" then
		return nil
	end
	return { id = user.id, name = user.name, username = user.login }
end

---@param on_done fun(user: AtlasUser|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_user(on_done)
	local cache_key = "github:current_user"
	local cached, ok = client.get_cache(cache_key)
	if ok then
		on_done(M.to_user(cached), nil)
		return nil
	end

	return client.gh({ "api", "user" }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch user")
			return
		end
		client.set_cache(cache_key, result)
		on_done(M.to_user(result), nil)
	end, { action = "Fetch current user" })
end

---@param slug string
---@param query string|nil
---@param on_done fun(users: AtlasUser[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_assignable_users(slug, query, on_done)
	if slug == "" then
		on_done(nil, "Missing repository slug")
		return nil
	end

	local q = vim.trim(tostring(query or "")):lower()
	return client.gh(
		{ "api", "--paginate", "--slurp", string.format("repos/%s/assignees?per_page=100", slug) },
		function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err)
				return
			end

			local users = {}
			for _, page in ipairs(result) do
				for _, raw in ipairs(page) do
					local user = M.to_user(raw)
					if user then
						if
							q == ""
							or user.name:lower():find(q, 1, true)
							or (user.username or ""):lower():find(q, 1, true)
						then
							table.insert(users, user)
						end
					end
				end
			end
			on_done(users, nil)
		end,
		{ action = "Fetch assignable users", slug = slug }
	)
end

return M
