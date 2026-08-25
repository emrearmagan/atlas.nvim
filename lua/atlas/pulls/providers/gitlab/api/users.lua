local M = {}

local service = require("atlas.providers.gitlab.client")
local mapper = require("atlas.pulls.providers.gitlab.api.mapper")
local json = require("atlas.core.json")

---@param on_done fun(user: PullsUser|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_user(on_done)
	local cache_key = "gitlab_pulls:user:me"
	local cached, ok = service.get_cache(cache_key)
	if ok then
		on_done(cached, nil)
		return nil
	end

	return service.request("GET", "/user", nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local user = mapper.to_user(result)
		if user then
			service.set_cache(cache_key, user)
		end
		on_done(user, nil)
	end, {
		action = "Fetch current user",
	})
end

---@param project_path string
---@param query string|nil
---@param on_done fun(users: PullsUser[]|nil, err: string|nil)
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
		local out = {}
		for _, raw in ipairs(json.safe_table(result)) do
			local user = mapper.to_user(raw)
			if user then
				table.insert(out, user)
			end
		end
		on_done(out, nil)
	end, {
		action = "List project members",
		project_path = project_path,
		query = q,
	})
end

return M
