local query = require("atlas.providers.bitbucket.query")

describe("Bitbucket pull request search", function()
	it("parses project and repository scopes before and after the query", function()
		for _, case in ipairs({
			{ "project:acme/WEB", { targets = { { workspace = "acme", project = "WEB" } } } },
			{
				'repo:acme/core title ~ "atlas" repo:other/app',
				{
					targets = { { workspace = "acme", repo = "core" }, { workspace = "other", repo = "app" } },
					query = 'title ~ "atlas"',
				},
			},
		}) do
			assert.same(case[2], query.parse(case[1]))
		end
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

		local parsed = assert(query.parse(query.for_repo("acme/core", view.search)))
		assert.same({ "merged" }, states)
		assert.equal('state = "MERGED"', query.filter(parsed, view._states))

		view._states = { "declined" }
		_, states = query.query(view)
		assert.same({ "declined" }, states)
	end)
end)
