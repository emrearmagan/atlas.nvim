local mapper = require("atlas.pulls.providers.gitlab.api.mapper")

describe("GitLab comment resolution metadata", function()
	local function resolved_note()
		return {
			id = 101,
			body = "Please update this",
			created_at = "2026-08-16T12:00:00Z",
			author = { id = 1, username = "author", name = "Author" },
			resolved_at = "2026-08-17T09:30:00Z",
			resolved_by = { id = 2, username = "reviewer", name = "Reviewer" },
		}
	end

	it("maps resolver and timestamp onto resolved thread roots", function()
		local comment = mapper.to_comment(resolved_note(), 101, "discussion-1", true)

		assert.are.equal("RESOLVED", comment.state)
		assert.are.equal("2026-08-17T09:30:00Z", comment.resolved_on)
		assert.same({
			id = "2",
			name = "Reviewer",
			username = "reviewer",
			nickname = "reviewer",
		}, comment.resolved_by)
	end)

	it("does not attach thread resolution metadata to replies", function()
		local note = resolved_note()
		note.id = 102
		local comment = mapper.to_comment(note, 101, "discussion-1", true)

		assert.are.equal("RESOLVED", comment.state)
		assert.is_nil(comment.resolved_on)
		assert.is_nil(comment.resolved_by)
	end)

	it("does not retain resolution metadata on unresolved roots", function()
		local comment = mapper.to_comment(resolved_note(), 101, "discussion-1", false)

		assert.is_nil(comment.state)
		assert.is_nil(comment.resolved_on)
		assert.is_nil(comment.resolved_by)
	end)
end)
