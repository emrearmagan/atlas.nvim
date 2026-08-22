require("atlas.pulls.providers.gitea.config")

---@type AtlasGiteaForgejoProviderConfig
local options = require("atlas.config").provider_options("gitea") or {}
local api_type = options.api_type or "gitea"

if api_type == "gitea" then
	return require("atlas.pulls.providers.gitea.gitea")
end
if api_type == "forgejo" then
	return require("atlas.pulls.providers.gitea.forgejo")
end

error("providers.gitea.api_type must be 'gitea' or 'forgejo'")
