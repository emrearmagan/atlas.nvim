local query = require("atlas.providers.bitbucket.query")

describe("Bitbucket pull request search", function()
	it("parses a repository scope", function()
		local parsed, err = query.parse('repo:acme/core title ~ "atlas"')

		assert.is_nil(err)
		assert.same({ { workspace = "acme", repo = "core" } }, parsed.targets)
		assert.equal('title ~ "atlas"', parsed.query)
	end)

	it("parses a project scope", function()
		local parsed, err = query.parse("project:acme/WEB")

		assert.is_nil(err)
		assert.same({ { workspace = "acme", project = "WEB" } }, parsed.targets)
		assert.is_nil(parsed.query)
	end)

	it("requires a scope", function()
		local parsed, err = query.parse('title ~ "atlas"')

		assert.is_nil(parsed)
		assert.is_string(err)
	end)

	it("parses repository scopes before and after the query", function()
		local parsed, err = query.parse('repo:acme/core title ~ "atlas" repo:other/app')

		assert.is_nil(err)
		assert.same({
			{ workspace = "acme", repo = "core" },
			{ workspace = "other", repo = "app" },
		}, parsed.targets)
		assert.equal('title ~ "atlas"', parsed.query)
	end)
end)
