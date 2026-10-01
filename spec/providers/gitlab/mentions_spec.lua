local mentions = require("atlas.providers.gitlab.mentions")

local function words(items)
	local result = {}
	for _, item in ipairs(items) do
		table.insert(result, item.word)
	end
	return result
end

describe("GitLab mentions", function()
	it("completes issue reporters, assignees, and comment authors by username", function()
		local completion = mentions.for_issues({
			issue = {
				reporter = { username = "reporter", name = "Issue Reporter" },
				assignee = { username = "alice", name = "Alice" },
			},
			details = {
				assignees = {
					{ username = "alice", name = "Alice" },
					{ username = "zoe", name = "Zoe" },
				},
			},
			comments = {
				{ author = { username = "commenter", name = "Comment Author" } },
			},
		})

		assert.same({ "@alice", "@commenter", "@reporter", "@zoe" }, words(completion.complete("")))
		assert.same({ "@commenter" }, words(completion.complete("@com")))
		assert.equal(
			"@gitlab-user",
			completion.format_mention({
				username = "gitlab-user",
				name = "Display Name",
			})
		)
	end)

	it("preserves pull request username completion sources", function()
		local context = {
			pr = {
				author = { username = "author-username", nickname = "author", name = "Author" },
			},
			details = { assignees = { { username = "assignee", name = "Assignee" } } },
			data = {
				reviewers = { { username = "reviewer", name = "Reviewer" } },
				comments = {
					{ author = { username = "comment-username", nickname = "commenter", name = "Commenter" } },
				},
				tasks = { { author = { nickname = "task-author" } } },
			},
			review_context = {
				mention_candidates = {
					{ username = "review-username", nickname = "review-author", name = "Review Author" },
				},
			},
			conversation = {
				{ author = { username = "conversation-username", nickname = "conversation", name = "Conversation" } },
			},
		}
		local original = vim.deepcopy(context)
		local completion = mentions.for_pulls(context)

		assert.same({
			"@assignee",
			"@author",
			"@commenter",
			"@conversation",
			"@review-author",
			"@reviewer",
			"@task-author",
		}, words(completion.complete("")))
		assert.equal(
			"@gitlab-user",
			completion.format_mention({
				username = "gitlab-username",
				nickname = "gitlab-user",
				name = "Display Name",
			})
		)
		assert.same(original, context)
	end)

	it("uses conversation authors and separately fetched reviewers without review data", function()
		local context = {
			pr = {},
			conversation = {
				{ author = { nickname = "commenter" } },
				{ author = { nickname = "task-author" }, is_task = true },
			},
			reviewers = { { username = "reviewer" } },
		}
		local original = vim.deepcopy(context)
		local completion = mentions.for_pulls(context)

		assert.same({ "@commenter", "@reviewer", "@task-author" }, words(completion.complete("")))
		assert.same(original, context)
	end)
end)
