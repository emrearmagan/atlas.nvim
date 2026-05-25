local M = {}

local service = require("atlas.issues.providers.gitlab.api.service")
local normalizer = require("atlas.issues.providers.gitlab.api.normalizer")

---@param on_done fun(user: IssueUser|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_user(on_done)
	local cache_key = "gitlab:user:me"
	local cached, ok = service.get_memory_cache(cache_key)
	if ok then
		on_done(cached, nil)
		return nil
	end

	return service.request("GET", "/user", nil, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		local user = normalizer.normalize_user(result)
		if user then
			service.set_memory_cache(cache_key, user)
		end
		on_done(user, nil)
	end)
end

---@class GitLabMember
---@field id integer
---@field username string
---@field name string

---@param project_path string
---@param query string|nil
---@param on_done fun(users: GitLabMember[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_members(project_path, query, on_done)
	if type(project_path) ~= "string" or project_path == "" then
		on_done(nil, "Missing project path")
		return nil
	end
	local q = vim.trim(tostring(query or ""))
	local endpoint = string.format("/projects/%s/members/all?per_page=100", service.url_encode(project_path))
	if q ~= "" then
		endpoint = endpoint .. "&query=" .. service.url_encode(q)
	end

	return service.request("GET", endpoint, nil, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err)
			return
		end
		local out = {}
		for _, raw in ipairs(result) do
			if type(raw) == "table" and tonumber(raw.id) and type(raw.username) == "string" then
				table.insert(out, {
					id = tonumber(raw.id),
					username = raw.username,
					name = type(raw.name) == "string" and raw.name or raw.username,
				})
			end
		end
		on_done(out, nil)
	end)
end

return M
