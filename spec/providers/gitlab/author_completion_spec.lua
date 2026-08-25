local author_completion = require("atlas.providers.gitlab.completion.author")

local function words(items)
	local result = {}
	for _, item in ipairs(items) do
		table.insert(result, item.word)
	end
	return result
end

describe("GitLab author completion", function()
	local original_trim

	before_each(function()
		original_trim = vim.trim
		vim.trim = function(value)
			return tostring(value or ""):match("^%s*(.-)%s*$")
		end
	end)

	after_each(function()
		vim.trim = original_trim
	end)

	it("completes issue reporters, assignees, and comment authors by username", function()
		local completion = author_completion.for_issues({
			issue = {
				reporter = { account_id = "reporter", display_name = "Issue Reporter" },
				assignee = { account_id = "alice", display_name = "Alice" },
			},
			details = {
				assignees = {
					{ account_id = "alice", display_name = "Alice" },
					{ account_id = "zoe", display_name = "Zoe" },
				},
			},
			comments = {
				{ author = { account_id = "commenter", display_name = "Comment Author" } },
			},
		})

		assert.same({ "@alice", "@commenter", "@reporter", "@zoe" }, words(completion.complete("")))
		assert.same({ "@commenter" }, words(completion.complete("@com")))
		assert.equal(
			"@gitlab-user",
			completion.format_mention({
				account_id = "gitlab-user",
				display_name = "Display Name",
			})
		)
	end)

	it("preserves pull request username completion sources", function()
		local completion = author_completion.for_pulls({
			pr = {
				author = { username = "author-username", nickname = "author", name = "Author" },
			},
			details = { assignees = { { username = "assignee", name = "Assignee" } } },
			reviewers = { { username = "reviewer", name = "Reviewer" } },
			review_context = {
				mention_candidates = {
					{ username = "review-username", nickname = "review-author", name = "Review Author" },
				},
			},
			comments = { { author = { username = "comment-username", nickname = "commenter", name = "Commenter" } } },
			conversation = {
				{ author = { username = "conversation-username", nickname = "conversation", name = "Conversation" } },
			},
		})

		assert.same({
			"@assignee",
			"@author",
			"@commenter",
			"@conversation",
			"@review-author",
			"@reviewer",
		}, words(completion.complete("")))
		assert.equal(
			"@gitlab-user",
			completion.format_mention({
				username = "gitlab-username",
				nickname = "gitlab-user",
				name = "Display Name",
			})
		)
	end)
end)
