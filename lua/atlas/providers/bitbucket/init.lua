local resolver = require("atlas.providers.bitbucket.resolve")
local repositories = require("atlas.providers.bitbucket.repositories")
local users = require("atlas.providers.bitbucket.users")

---@type AtlasProvider
return {
	id = "bitbucket",
	name = "Bitbucket",
	resolver = resolver,
	domains = {
		pulls = {
			module = "atlas.pulls.providers.bitbucket",
			icon = { icon = "", hl_group = "AtlasBitbucketTheme" },
			bookmark_key = "S",
		},
	},
	capabilities = {
		repository = repositories,
		users = users,
	},
}
