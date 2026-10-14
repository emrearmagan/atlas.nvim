local resolver = require("atlas.providers.forge.resolve")

local M = {}

---@param id ForgeProviderId
---@return AtlasProvider
function M.new(id)
	local service = require("atlas.providers.forge." .. id .. ".api")
	local icon = { icon = id == "gitea" and "" or "", hl_group = "Atlas" .. service.name .. "Theme" }
	return {
		id = id,
		name = service.name,
		hostname = service.hostname,
		resolver = resolver.new(id, id == "gitea" and "gitea.com" or nil),
		domains = {
			pulls = { module = "atlas.pulls.providers.forge." .. id, icon = icon, bookmark_key = "S" },
			issues = { module = "atlas.issues.providers.forge." .. id, icon = icon, bookmark_key = "S" },
		},
		capabilities = {
			repository = service.repository,
			users = service.users,
			notifications = service.notifications,
			completion = require("atlas.providers.forge.completion").new(service),
		},
	}
end

return M
