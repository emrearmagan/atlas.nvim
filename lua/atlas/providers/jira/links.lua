local M = {}

local config = require("atlas.config")

---Extract Jira references from PR titles and source branches.
---These are text references; they do not imply a Jira development-panel association.
---@param ... string|nil
---@return AtlasRelatedItem[]
function M.resolve(...)
	local options = config.provider_options("jira") or {}
	local base_url = type(options.base_url) == "string" and options.base_url:gsub("/+$", "") or ""
	if not base_url:match("^https?://") then
		return {}
	end

	local links, seen = {}, {}
	for index = 1, select("#", ...) do
		local value = select(index, ...)
		if type(value) == "string" then
			for key in value:gmatch("%f[%w_]([A-Z][A-Z0-9_]*%-%d+)%f[^%w_]") do
				if not seen[key] then
					seen[key] = true
					table.insert(links, {
						kind = "issue",
						url = base_url .. "/browse/" .. key,
						key = key,
						relationship = "references",
					})
				end
			end
		end
	end
	return links
end

return M
