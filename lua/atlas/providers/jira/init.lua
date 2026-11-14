local url = require("atlas.providers.url")
local resolver = require("atlas.providers.jira.resolve")
local users = require("atlas.providers.jira.users")
local links = require("atlas.providers.jira.links")

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
			icon = { icon = "󰌃", hl_group = "AtlasJiraTheme" },
			bookmark_key = "J",
			bookmark_label = "JQL",
		},
	},
	capabilities = {
		-- repository = nil,
		-- notifications = nil,
		users = users,
		completion = require("atlas.providers.jira.completion"),
		fetch_links = links.fetch,
	},
}
