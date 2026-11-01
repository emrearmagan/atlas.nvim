local completion = require("atlas.providers.forge.completion")
local resolver = require("atlas.providers.forge.resolve")
local service = require("atlas.providers.forge.gitea.api")

---@type AtlasProvider
return {
	id = "gitea",
	name = "Gitea",
	hostname = service.hostname,
	resolver = resolver.new(service),
	domains = {
		pulls = {
			module = "atlas.pulls.providers.forge.gitea",
			icon = { icon = "", hl_group = "AtlasGiteaTheme" },
			bookmark_key = "S",
		},
		issues = {
			module = "atlas.issues.providers.forge.gitea",
			icon = { icon = "", hl_group = "AtlasGiteaTheme" },
			bookmark_key = "S",
		},
	},
	capabilities = {
		completion = completion.new(service),
		repository = service.repository,
		notifications = service.notifications,
		users = service.users,
	},
}
