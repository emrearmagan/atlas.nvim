local M = {}

local service = require("atlas.issues.providers.gitlab.api.service")

---@class GitLabLabel
---@field id integer
---@field name string
---@field color string|nil
---@field description string|nil

---@param project_path string
---@param on_done fun(labels: GitLabLabel[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list(project_path, on_done)
	if type(project_path) ~= "string" or project_path == "" then
		on_done(nil, "Missing project path")
		return nil
	end
	local endpoint = string.format("/projects/%s/labels?per_page=100", service.url_encode(project_path))
	return service.request("GET", endpoint, nil, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err)
			return
		end
		local out = {}
		for _, raw in ipairs(result) do
			if type(raw) == "table" and type(raw.name) == "string" then
				local color = type(raw.color) == "string" and raw.color or nil
				if color and color:sub(1, 1) == "#" then
					color = color:sub(2)
				end
				table.insert(out, {
					id = tonumber(raw.id),
					name = raw.name,
					color = color,
					description = type(raw.description) == "string" and raw.description or nil,
				})
			end
		end
		on_done(out, nil)
	end, {
		action = "List labels",
		project = project_path,
	})
end

return M
