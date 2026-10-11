local query = require("atlas.providers.gitlab.query")

describe("GitLab search", function()
	it("uses configured MR states until the dashboard changes them", function()
		local view = { state = "all" }
		assert.same({ "all" }, query.api_states(view))

		view._states = { "open", "declined" }
		assert.same({ "opened", "closed" }, query.api_states(view))
	end)

	it("roundtrips and clears review filters", function()
		local view = {
			scope = "reviews_for_me",
			review_states = { "UNREVIEWED", "REVIEW_STARTED" },
			labels = "needs review",
		}
		local text = query.query(view)
		local edited = {}
		assert.is_true(query.apply(edited, text))
		assert.same(view.review_states, edited.review_states)
		assert.equal(text, query.query(edited))

		assert.is_true(query.apply(edited, "is:open scope:reviews_for_me"))
		assert.is_nil(edited.review_states)
	end)

	it("rejects invalid review states without changing the view", function()
		local view = { scope = "reviews_for_me", review_states = { "APPROVED" } }
		local original = vim.deepcopy(view)
		local ok, err = query.apply(view, "is:open review_states:UNREVIEWED,UNREVIEWD")

		assert.is_false(ok)
		assert.equal("Unknown review state: UNREVIEWD", err)
		assert.same(original, view)
	end)

	it("roundtrips issue states and filters", function()
		local view = { state = "closed", project = "group/project", labels = "needs triage" }
		local text = query.issue_query(view)
		local edited = {}
		assert.is_true(query.apply_issue(edited, text))
		assert.equal(text, query.issue_query(edited))
	end)
end)
