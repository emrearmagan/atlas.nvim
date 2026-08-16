require("atlas.pulls.providers.gitea.config")

---@type AtlasGiteaForgejoPullsConfig
local options = require("atlas.providers").options("gitea", "pulls") or {}
local api_type = options.api_type or "gitea"

if api_type == "gitea" then
	return require("atlas.pulls.providers.gitea.gitea")
end
if api_type == "forgejo" then
	return require("atlas.pulls.providers.gitea.forgejo")
end

error("pulls.providers.gitea.api_type must be 'gitea' or 'forgejo'")
