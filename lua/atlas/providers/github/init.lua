local resolver = require("atlas.providers.github.resolve")
local repositories = require("atlas.providers.github.repositories")
local notifications = require("atlas.providers.github.notifications")
local users = require("atlas.providers.github.users")

---@type AtlasProvider
return {
	id = "github",
	name = "GitHub",
	resolver = resolver,
	domains = {
		pulls = {
			module = "atlas.pulls.providers.github",
			icon = { icon = "", hl_group = "AtlasGitHubTheme" },
			bookmark_key = "S",
		},
		issues = {
			module = "atlas.issues.providers.github",
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
