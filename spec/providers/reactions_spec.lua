local github = require("atlas.providers.github.mapper")
local gitlab = require("atlas.providers.gitlab.mapper")

describe("provider reactions", function()
	it("maps GitHub GraphQL reaction groups with the returned reactors and the viewer's own", function()
		assert.same(
			{
				{ name = "tada", count = 12, users = { { name = "Alice", username = "alice" } }, reacted = true },
				{ name = "thumbsup", count = 1, users = { { name = "bot", username = "bot" } }, reacted = false },
			},
			github.graphql_reactions({
				{
					content = "HOORAY",
					viewerHasReacted = true,
					reactors = { totalCount = 12, nodes = { { login = "alice", name = "Alice" } } },
				},
				{ content = "THUMBS_UP", reactors = { totalCount = 1, nodes = { { login = "bot" } } } },
				{ content = "EYES", reactors = { totalCount = 0, nodes = {} } },
				{ content = "UNKNOWN", reactors = { totalCount = 5, nodes = {} } },
			})
		)
	end)

	it("counts GitLab awards per emoji in the order they were first given and marks the viewer's", function()
		local alice = { name = "Alice", username = "alice" }
		local bob = { name = "Bob", username = "bob" }
		assert.same(
			{
				{
					name = "fire",
					count = 2,
					users = {
						{ id = "", name = "Alice", username = "alice" },
						{ id = "", name = "Bob", username = "bob" },
					},
					reacted = true,
				},
				{
					name = "thumbsup",
					count = 1,
					users = { { id = "", name = "Alice", username = "alice" } },
					reacted = false,
				},
			},
			gitlab.award_reactions({
				{ name = "fire", user = alice },
				{ name = "thumbsup", user = alice },
				{ name = "fire", user = bob },
			}, "bob")
		)
		assert.same({}, gitlab.award_reactions(nil))
	end)
end)
