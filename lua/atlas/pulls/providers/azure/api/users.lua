local M = {}

local service = require("atlas.pulls.providers.azure.api.service")
local request_scope = require("atlas.core.requests")

---@param on_done fun(user: PullsUser|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_user(on_done)
	local cache_key = "user:me"
	local cached, ok = service.get_persistent_cache(cache_key)
	if ok then
		on_done(cached, nil)
		return nil
	end

	return service.request("GET", "/_apis/ConnectionData", nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local identity = result.authenticatedUser
		---@type PullsUser
		local user = {
			name = identity.providerDisplayName,
			id = identity.id,
			username = identity.properties.Account["$value"],
		}
		service.set_persistent_cache(cache_key, user)
		on_done(user, nil)
	end, { action = "Fetch current user" }, "7.1-preview.1")
end

---@param endpoint string
---@param on_done fun(items: table[]|nil, err: string|nil)
---@return AtlasRequestScope
local function fetch_list(endpoint, on_done)
	local scope = request_scope.new()
	local items = {}
	local function fetch_page(skip)
		local query = service.build_query({ ["$top"] = 100, ["$skip"] = skip })
		scope.run(function(done)
			return service.request("GET", endpoint .. query, nil, done, { action = "Fetch reviewer candidates" })
		end, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			vim.list_extend(items, result.value)
			if #result.value == 100 then
				fetch_page(skip + 100)
			else
				on_done(items, nil)
			end
		end)
	end
	fetch_page(0)
	return scope
end

---@param project string
---@param on_done fun(members: table[]|nil, err: string|nil)
---@return AtlasRequestScope
function M.fetch_project_members(project, on_done)
	local endpoint = "/_apis/projects/" .. service.url_encode(project) .. "/teams"
	local scope = request_scope.new()
	scope.run(function(done)
		return fetch_list(endpoint, done)
	end, function(teams, err)
		if err then
			on_done(nil, err)
			return
		end
		local starts = {}
		for _, team in ipairs(teams) do
			table.insert(starts, function(done)
				return fetch_list(endpoint .. "/" .. team.id .. "/members", done)
			end)
		end
		scope.all(starts, function(results, errors)
			local _, error = next(errors)
			if error then
				on_done(nil, error)
				return
			end
			local members = {}
			for _, result in ipairs(results) do
				for _, member in ipairs(result) do
					table.insert(members, member.identity)
				end
			end
			on_done(members, nil)
		end)
	end)
	return scope
end

return M
