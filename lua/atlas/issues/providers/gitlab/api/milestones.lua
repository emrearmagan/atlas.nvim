local M = {}

local service = require("atlas.issues.providers.gitlab.api.service")

---@class GitLabMilestone
---@field id integer
---@field iid integer|nil
---@field title string
---@field description string|nil
---@field state string|nil

---@param project_path string
---@param on_done fun(milestones: GitLabMilestone[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list(project_path, on_done)
	if type(project_path) ~= "string" or project_path == "" then
		on_done(nil, "Missing project path")
		return nil
	end
	local endpoint = string.format(
		"/projects/%s/milestones?per_page=100&state=active",
		service.url_encode(project_path)
	)
	return service.request("GET", endpoint, nil, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err)
			return
		end
		local out = {}
		for _, raw in ipairs(result) do
			if type(raw) == "table" and tonumber(raw.id) and type(raw.title) == "string" then
				table.insert(out, {
					id = tonumber(raw.id),
					iid = tonumber(raw.iid),
					title = raw.title,
					description = type(raw.description) == "string" and raw.description or nil,
					state = type(raw.state) == "string" and raw.state or nil,
				})
			end
		end
		on_done(out, nil)
	end, {
		action = "List milestones",
		project = project_path,
	})
end

return M
