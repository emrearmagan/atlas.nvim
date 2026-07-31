local M = {}

local MODULES = {
	github = "atlas.pulls.providers.github",
	bitbucket = "atlas.pulls.providers.bitbucket",
	gitlab = "atlas.pulls.providers.gitlab",
}

---@param id string
---@return PullsProvider|nil
function M.get(id)
	local path = MODULES[id]
	return path and require(path) or nil
end

return M
