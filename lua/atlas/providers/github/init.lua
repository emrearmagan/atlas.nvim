local client = require("atlas.providers.github.client")
local resolver = require("atlas.providers.github.resolve")
local repositories = require("atlas.providers.github.repositories")
local notifications = require("atlas.providers.github.notifications")
local users = require("atlas.providers.github.users")

---@type AtlasProvider
return {
	id = "github",
	name = "GitHub",
	hostname = client.hostname,
	resolver = resolver,
	domains = {
		pulls = {
			module = "atlas.pulls.providers.github",
			actions = "atlas.pulls.providers.github.actions.registry",
			icon = { icon = "", hl_group = "AtlasGitHubTheme" },
			bookmark_key = "S",
		},
		issues = {
			module = "atlas.issues.providers.github",
			actions = "atlas.issues.providers.github.actions.registry",
			icon = { icon = "", hl_group = "AtlasGitHubTheme" },
			bookmark_key = "S",
		},
	},
	capabilities = {
		repository = repositories,
		notifications = notifications,
		users = users,
	},
}
