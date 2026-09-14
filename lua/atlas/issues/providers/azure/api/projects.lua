local M = {}

local request_scope = require("atlas.core.requests")
local service = require("atlas.pulls.providers.azure.api.service")

---@param on_done fun(projects: table[]|nil, err: string|nil)
---@return AtlasRequestScope|nil
function M.fetch_projects(on_done)
	local cached, found = service.get_cache("issue-projects")
	if found then
		on_done(cached, nil)
		return nil
	end

	local projects = {}
	local scope = request_scope.new()
	---@param continuation_token string|nil
	local function fetch_page(continuation_token)
		local query = service.build_query({ ["$top"] = 100, continuationToken = continuation_token })
		scope.run(function(done)
			return service.request("GET", "/_apis/projects" .. query, nil, done, { action = "Fetch projects" })
		end, function(result, err, headers)
			if err then
				on_done(nil, err)
				return
			end
			vim.list_extend(projects, result.value)
			local next_token = headers["x-ms-continuationtoken"]
			if next_token then
				fetch_page(next_token)
				return
			end
			service.set_cache("issue-projects", projects)
			on_done(projects, nil)
		end)
	end

	fetch_page(nil)
	return scope
end

return M
