local providers = require("atlas.providers")

---@param domain "pulls"|"issues"
---@return AtlasGiteaForgejoConfig
local function config(domain)
	local configured = providers.options("gitea", domain)
	if configured ~= nil then
		return configured
	end
	if domain == "issues" then
		return providers.options("gitea", "pulls") or {}
	end
	return {}
end

---@param domain "pulls"|"issues"
---@return "gitea"|"forgejo"
local function api_type(domain)
	return config(domain).api_type == "forgejo" and "forgejo" or "gitea"
end

---@param domain "pulls"|"issues"
---@return table
local function client(domain)
	return require("atlas.providers.gitea." .. api_type(domain) .. ".client")[domain]
end

return {
	api_type = api_type,
	pulls = client("pulls"),
	issues = client("issues"),
}
