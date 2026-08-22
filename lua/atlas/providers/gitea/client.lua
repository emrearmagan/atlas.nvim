local config = require("atlas.config")

---@return AtlasGiteaForgejoProviderConfig
local function provider_config()
	return config.provider_options("gitea") or {}
end

---@return "gitea"|"forgejo"
local function api_type()
	return provider_config().api_type == "forgejo" and "forgejo" or "gitea"
end

---@param domain "pulls"|"issues"
---@return table
local function client(domain)
	return require("atlas.providers.gitea." .. api_type() .. ".client")[domain]
end

return {
	api_type = api_type,
	pulls = client("pulls"),
	issues = client("issues"),
}
