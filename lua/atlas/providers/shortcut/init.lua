local resolver = require("atlas.providers.shortcut.resolve")
local users = require("atlas.providers.shortcut.users")

---@type AtlasProvider
return {
	id = "shortcut",
	name = "Shortcut",
	hostname = function()
		return "app.shortcut.com"
	end,
	resolver = resolver,
	domains = {
		issues = {
			module = "atlas.issues.providers.shortcut",
			icon = { icon = "S", hl_group = "AtlasShortcutTheme" },
			bookmark_key = "S",
			bookmark_label = "Search",
		},
	},
	capabilities = {
		-- repository = nil,
		-- notifications = nil,
		users = users,
		completion = require("atlas.providers.shortcut.completion"),
		-- actions = nil,
	},
}
