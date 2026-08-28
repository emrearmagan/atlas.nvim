local search = require("atlas.providers.bitbucket.completion.search")

describe("Bitbucket pull request search", function()
	it("parses a repository scope", function()
		local parsed, err = search.parse('repo:acme/core title ~ "atlas"')

		assert.is_nil(err)
		assert.same({ { workspace = "acme", repo = "core" } }, parsed.targets)
		assert.equal('title ~ "atlas"', parsed.query)
	end)

	it("parses a project scope", function()
		local parsed, err = search.parse("project:acme/WEB")

		assert.is_nil(err)
		assert.same({ { workspace = "acme", project = "WEB" } }, parsed.targets)
		assert.is_nil(parsed.query)
	end)

	it("requires a scope", function()
		local parsed, err = search.parse('title ~ "atlas"')

		assert.is_nil(parsed)
		assert.is_string(err)
	end)

	it("parses repository scopes before and after the query", function()
		local parsed, err = search.parse('repo:acme/core title ~ "atlas" repo:other/app')

		assert.is_nil(err)
		assert.same({
			{ workspace = "acme", repo = "core" },
			{ workspace = "other", repo = "app" },
		}, parsed.targets)
		assert.equal('title ~ "atlas"', parsed.query)
	end)
end)
