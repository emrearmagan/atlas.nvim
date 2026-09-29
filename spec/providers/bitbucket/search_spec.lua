local query = require("atlas.providers.bitbucket.query")

describe("Bitbucket pull request search", function()
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

	it("preserves status filters before the current repository is resolved", function()
		local view = { current_repo = true, search = 'state   = "MERGED"' }
		local _, states = query.query(view)
		view._states = states

		local parsed = assert(query.parse(query.for_repo("acme", "core", view.search)))
		assert.same({ "merged" }, states)
		assert.equal('state = "MERGED"', query.filter(parsed, view._states))

		view._states = { "declined" }
		_, states = query.query(view)
		assert.same({ "declined" }, states)
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
