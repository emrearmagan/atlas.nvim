local author_completion = require("atlas.providers.bitbucket.completion.author")

describe("Bitbucket author completion", function()
	local original_tbl_values

	before_each(function()
		original_tbl_values = vim.tbl_values
		vim.tbl_values = function(value)
			local result = {}
			for _, item in pairs(value or {}) do
				table.insert(result, item)
			end
			return result
		end
	end)

	after_each(function()
		vim.tbl_values = original_tbl_values
	end)

	it("preserves pull request completion sources and mention formatting", function()
		local comments = {
			{ author = { id = "commenter", name = "Commenter" }, content_raw = "Hi @{author}" },
		}
		local completion = author_completion.for_pulls({
			pr = {
				author = { id = "author", name = "Author" },
				reviewers = { { id = "reviewer", name = "Reviewer" } },
			},
			comments = comments,
			tasks = {},
			review_context = {
				mention_candidates = { { id = "review-author", name = "Review Author" } },
			},
		})

		assert.same({
			{ abbr = "@Author", menu = "mention", word = "@{author}" },
			{ abbr = "@Commenter", menu = "mention", word = "@{commenter}" },
			{ abbr = "@Review Author", menu = "mention", word = "@{review-author}" },
			{ abbr = "@Reviewer", menu = "mention", word = "@{reviewer}" },
		}, completion.complete(""))
		assert.same(
			{ { abbr = "@Reviewer", menu = "mention", word = "@{reviewer}" } },
			completion.complete("@reviewer")
		)
		assert.equal("@{author}", completion.format_mention({ id = "author", name = "Author" }))

		completion.resolve_items()
		assert.equal("Hi @Author", comments[1].content_display)
	end)
end)
