local config = require("atlas.config")
local provider = require("atlas.providers.azure")
local query = require("atlas.providers.azure.query")

describe("Azure provider logic", function()
	local original_options

	before_each(function()
		original_options = config.options
		config.options = { providers = { azure = {} } }
	end)

	after_each(function()
		config.options = original_options
	end)

	it("includes selected states and Azure filters in search queries", function()
		local view = {
			project = "Platform",
			repository = "api",
			scope = "assigned_to_me",
			extra_params = { ["searchCriteria.targetRefName"] = "refs/heads/main" },
		}
		local filter, states = query.query(view)
		assert.equal(
			"is:open project:Platform repository:api scope:assigned_to_me "
				.. "param.searchCriteria.targetRefName:refs/heads/main",
			filter
		)
		assert.same({ "open" }, states)
		view._states = { "merged", "declined" }
		filter, states = query.query(view)
		assert.same({ "merged", "declined" }, states)
		assert.matches("^is:merged,declined ", filter)
	end)

	it("uses a normalized organization namespace to prevent bookmark collisions", function()
		config.options.providers.azure.base_url = "https://DEV.AZURE.COM/ACME///"
		assert.equal("dev.azure.com/acme", provider.hostname())
		config.options.providers.azure.base_url = "https://dev.azure.com/other"
		assert.equal("dev.azure.com/other", provider.hostname())
	end)
end)
