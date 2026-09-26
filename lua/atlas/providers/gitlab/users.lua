local service = require("atlas.providers.gitlab.client")
local json = require("atlas.core.json")

local M = {}

---@param raw any
---@return AtlasUser|nil
function M.to_user(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local username = json.safe_str(raw.username) or ""
	if username == "" then
		return nil
	end
	local name = json.safe_str(raw.name) or ""
	local id = json.safe_str(raw.id) or ""
	return {
		id = id:match("([^/]+)$") or id,
		name = name ~= "" and name or username,
		username = username,
	}
end

---@param on_done fun(user: AtlasUser|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_user(on_done)
	local cache_key = "gitlab:current_user"
	local cached, ok = service.get_cache(cache_key)
	if ok then
		on_done(M.to_user(cached), nil)
		return nil
	end

	return service.request("GET", "/user", nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		if result then
			service.set_cache(cache_key, result)
		end
		on_done(M.to_user(result), nil)
	end, { action = "Fetch current user" })
end

---@param project_path string
---@param query string|nil
---@param on_done fun(users: AtlasUser[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_members(project_path, query, on_done)
	if project_path == "" then
		on_done(nil, "Missing project path")
		return nil
	end
	local q = vim.trim(tostring(query or ""))
	local endpoint = string.format("/projects/%s/members/all?per_page=100", service.url_encode(project_path))
	if q ~= "" then
		endpoint = endpoint .. "&query=" .. service.url_encode(q)
	end

	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local users = {}
		for _, raw in ipairs(json.safe_table(result)) do
			local user = M.to_user(raw)
			if user then
				table.insert(users, user)
			end
		end
		on_done(users, nil)
	end, {
		action = "List project members",
		project_path = project_path,
		query = q,
	})
end

return M
