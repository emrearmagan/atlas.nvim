local url = require("atlas.providers.url")
local resolver = require("atlas.providers.jira.resolve")
local users = require("atlas.providers.jira.users")

---@type AtlasProvider
return {
	id = "jira",
	name = "Jira",
	hostname = function()
		local base = url.configured_base("jira")
		return base and base.host or nil
	end,
	resolver = resolver,
	domains = {
		issues = {
			module = "atlas.issues.providers.jira",
			actions = "atlas.issues.providers.jira.actions.registry",
			icon = { icon = "󰌃", hl_group = "AtlasJiraTheme" },
			bookmark_key = "J",
			bookmark_label = "JQL",
		},
	},
	capabilities = {
		-- repository = nil,
		-- notifications = nil,
		users = users,
	},
}
