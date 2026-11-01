local completion = require("atlas.providers.forge.completion")
local resolver = require("atlas.providers.forge.resolve")
local service = require("atlas.providers.forge.forgejo.api")

---@type AtlasProvider
return {
	id = "forgejo",
	name = "Forgejo",
	hostname = service.hostname,
	resolver = resolver.new(service),
	domains = {
		pulls = {
			module = "atlas.pulls.providers.forge.forgejo",
			icon = { icon = "", hl_group = "AtlasForgejoTheme" },
			bookmark_key = "S",
		},
		issues = {
			module = "atlas.issues.providers.forge.forgejo",
			icon = { icon = "", hl_group = "AtlasForgejoTheme" },
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
