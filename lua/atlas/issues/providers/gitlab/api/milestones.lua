local M = {}

local json = require("atlas.core.json")
local service = require("atlas.providers.gitlab.client")

---@class GitLabMilestone : IssueMilestone
---@field id integer

---@param project_path string
---@param on_done fun(milestones: IssueMilestone[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list(project_path, on_done)
	if project_path == "" then
		on_done(nil, "Missing project path")
		return nil
	end
	local endpoint =
		string.format("/projects/%s/milestones?per_page=100&state=active", service.url_encode(project_path))
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local out = {}
		for _, raw_value in ipairs(json.safe_table(result)) do
			local raw = json.safe_table(raw_value)
			local id = tonumber(raw.id)
			local title = json.safe_str(raw.title)
			if id and title then
				table.insert(out, {
					id = id,
					title = title,
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
