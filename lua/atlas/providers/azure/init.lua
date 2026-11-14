local url = require("atlas.providers.url")

---@type AtlasProvider
return {
	id = "azure",
	name = "Azure DevOps",
	hostname = function()
		local base = url.configured_base("azure")
		return base and (base.host .. base.path:lower()) or nil
	end,
	resolver = require("atlas.providers.azure.resolve"),
	domains = {
		pulls = {
			module = "atlas.pulls.providers.azure",
			icon = { icon = "", hl_group = "AtlasAzureTheme" },
		},
		issues = {
			module = "atlas.issues.providers.azure",
			icon = { icon = "", hl_group = "AtlasAzureTheme" },
			bookmark_key = "S",
			bookmark_label = "WIQL",
		},
	},
	capabilities = {
		users = require("atlas.providers.azure.users"),
		repository = require("atlas.providers.azure.repositories"),
		-- notifications = nil,
		completion = require("atlas.providers.azure.completion"),
		-- actions = nil,
	},
}
