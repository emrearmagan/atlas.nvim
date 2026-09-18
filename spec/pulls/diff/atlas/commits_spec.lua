local commits = require("atlas.pulls.diff.atlas.commits")

describe("pulls.diff.atlas.commits format_commit_lines", function()
	it("keeps every line of a multi-line commit message, not just the summary", function()
		local lines = commits.format_commit_lines({
			hash = "abc123def456",
			message = "Fix bug\n\nThis explains why the fix is needed.\nSecond body line.",
			author_name = "Alice",
			date = "2024-01-02T03:04:05Z",
		})

		assert.same({
			"Fix bug",
			"",
			"This explains why the fix is needed.",
			"Second body line.",
			"",
			"Author: Alice",
			"Date: 2024-01-02",
			"Commit: abc123def456",
		}, lines)
	end)

	it("normalizes CRLF line endings before splitting", function()
		local lines = commits.format_commit_lines({
			hash = "abc123",
			message = "Headline\r\n\r\nBody line",
			author_name = "Alice",
			date = "2024-01-02T00:00:00Z",
		})

		assert.equal("Headline", lines[1])
		assert.equal("", lines[2])
		assert.equal("Body line", lines[3])
	end)

	it("trims trailing blank lines from the message before appending metadata", function()
		local lines = commits.format_commit_lines({
			hash = "abc123",
			message = "Headline\n\n\n",
			author_name = "Alice",
			date = "2024-01-02T00:00:00Z",
		})

		assert.same({
			"Headline",
			"",
			"Author: Alice",
			"Date: 2024-01-02",
			"Commit: abc123",
		}, lines)
	end)

	it("prefers the author nickname over the display name when both are present", function()
		local lines = commits.format_commit_lines({
			hash = "abc123",
			message = "Headline",
			author_name = "Alice Example",
			author_nickname = "alice",
			date = "2024-01-02T00:00:00Z",
		})

		assert.equal("Author: alice", lines[3])
	end)

	it("falls back to the display name when the nickname is empty", function()
		local lines = commits.format_commit_lines({
			hash = "abc123",
			message = "Headline",
			author_name = "Alice Example",
			author_nickname = "",
			date = "2024-01-02T00:00:00Z",
		})

		assert.equal("Author: Alice Example", lines[3])
	end)

	it("falls back to Unknown when no author information is present", function()
		local lines = commits.format_commit_lines({
			hash = "abc123",
			message = "Headline",
			date = "2024-01-02T00:00:00Z",
		})

		assert.equal("Author: Unknown", lines[3])
	end)

	it("prefers the full hash over the short hash for the Commit line", function()
		local lines = commits.format_commit_lines({
			hash = "abc123def456",
			short_hash = "abc123d",
			message = "Headline",
			author_name = "Alice",
			date = "2024-01-02T00:00:00Z",
		})

		assert.equal("Commit: abc123def456", lines[#lines])
	end)
end)
