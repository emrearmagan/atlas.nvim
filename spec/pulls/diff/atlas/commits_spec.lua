for _, module in ipairs({
	"atlas.pulls.diff.atlas.commits",
	"atlas.pulls.ui.detail.tabs.commits.keymaps",
}) do
	local commits = require(module)

	describe(module .. " format_commit_lines", function()
		it("preserves the full message and appends metadata after one blank line", function()
			local lines = commits.format_commit_lines({
				hash = "abc123def456",
				short_hash = "abc123d",
				message = "Fix bug\r\n\r\nThis explains the fix.\r\nSecond body line.\r\n\r\n",
				author_name = "Alice Example",
				author_nickname = "alice",
				date = "2024-01-02T03:04:05Z",
			})

			assert.same({
				"Fix bug",
				"",
				"This explains the fix.",
				"Second body line.",
				"",
				"Author: alice",
				"Date: 2024-01-02",
				"Commit: abc123def456",
			}, lines)
		end)

		it("uses the display name or Unknown when the nickname is missing", function()
			for _, author in ipairs({
				{ nickname = "", name = "Alice Example", expected = "Alice Example" },
				{ expected = "Unknown" },
			}) do
				local lines = commits.format_commit_lines({
					hash = "abc123",
					message = "Headline",
					author_name = author.name,
					author_nickname = author.nickname,
					date = "2024-01-02T00:00:00Z",
				})

				assert.equal("Author: " .. author.expected, lines[3])
			end
		end)
	end)
end
