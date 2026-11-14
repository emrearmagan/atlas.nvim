local M = {}

local service = require("atlas.providers.azure.client")

---@param on_done fun(projects: table[]|nil, err: string|nil)
---@return AtlasRequestScope|nil
function M.fetch_projects(on_done)
	local cached, found = service.get_cache("issue-projects")
	if found then
		on_done(cached, nil)
		return nil
	end

	return service.fetch_all("/_apis/projects", {}, { action = "Fetch projects" }, function(projects, err)
		if not projects then
			on_done(nil, err)
			return
		end
		service.set_cache("issue-projects", projects)
		on_done(projects, nil)
	end)
end

return M
