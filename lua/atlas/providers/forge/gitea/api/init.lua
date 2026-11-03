---@type ForgeService
local service = require("atlas.providers.forge.api").new("gitea", "Gitea", "gitea.com")

return service
