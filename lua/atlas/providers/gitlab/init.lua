local resolver = require("atlas.providers.gitlab.resolve")
local repositories = require("atlas.providers.gitlab.repositories")
local notifications = require("atlas.providers.gitlab.notifications")
local users = require("atlas.providers.gitlab.users")

---@type AtlasProvider
return {
	id = "gitlab",
	name = "GitLab",
	resolver = resolver,
	domains = {
		pulls = {
			module = "atlas.pulls.providers.gitlab",
			icon = { icon = "", hl_group = "AtlasGitLabTheme" },
			bookmark_key = "S",
		},
		issues = {
			module = "atlas.issues.providers.gitlab",
			icon = { icon = "", hl_group = "AtlasGitLabTheme" },
			bookmark_key = "S",
		},
	},
	capabilities = {
		repository = repositories,
		notifications = notifications,
		users = users,
	},
}
