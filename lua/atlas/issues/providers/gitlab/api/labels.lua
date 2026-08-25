local M = {}

local json = require("atlas.core.json")
local service = require("atlas.providers.gitlab.client")

---@param project_path string
---@param on_done fun(labels: IssueLabel[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list(project_path, on_done)
	if project_path == "" then
		on_done(nil, "Missing project path")
		return nil
	end
	local endpoint = string.format("/projects/%s/labels?per_page=100", service.url_encode(project_path))
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local out = {}
		for _, raw_value in ipairs(json.safe_table(result)) do
			local raw = json.safe_table(raw_value)
			local name = json.safe_str(raw.name)
			if name and name ~= "" then
				local color = json.safe_str(raw.color)
				if color and color:sub(1, 1) == "#" then
					color = color:sub(2)
				end
				table.insert(out, {
					name = name,
					color = color,
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
