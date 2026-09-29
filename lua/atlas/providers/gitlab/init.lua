local url = require("atlas.providers.url")
local resolver = require("atlas.providers.gitlab.resolve")
local repositories = require("atlas.providers.gitlab.repositories")
local notifications = require("atlas.providers.gitlab.notifications")
local users = require("atlas.providers.gitlab.users")

---@type AtlasProvider
return {
	id = "gitlab",
	name = "GitLab",
	hostname = function()
		local base = url.configured_base("gitlab")
		return base and base.host or nil
	end,
	resolver = resolver,
	domains = {
		pulls = {
			module = "atlas.pulls.providers.gitlab",
			actions = "atlas.pulls.providers.gitlab.actions.registry",
			icon = { icon = "", hl_group = "AtlasGitLabTheme" },
			bookmark_key = "S",
		},
		issues = {
			module = "atlas.issues.providers.gitlab",
			actions = "atlas.issues.providers.gitlab.actions.registry",
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
