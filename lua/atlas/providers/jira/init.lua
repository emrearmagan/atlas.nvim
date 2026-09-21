local resolver = require("atlas.providers.jira.resolve")
local users = require("atlas.providers.jira.users")

---@type AtlasProvider
return {
	id = "jira",
	name = "Jira",
	resolver = resolver,
	domains = {
		issues = {
			module = "atlas.issues.providers.jira",
			icon = { icon = "󰌃", hl_group = "AtlasJiraTheme" },
			bookmark_key = "J",
			bookmark_label = "JQL",
		},
	},
	capabilities = {
		users = users,
	},
}
