local mentions = require("atlas.providers.bitbucket.mentions")

local function context()
	return {
		pr = {
			author = { id = "author", name = "Author" },
			reviewers = { { id = "reviewer", name = "Reviewer" } },
		},
		data = {
			comments = {
				{ author = { id = "commenter", name = "Commenter" }, content_raw = "Hi @{author} and @{unknown}" },
			},
			tasks = {
				{ author = { id = "task-author", nickname = "Task Author" }, content_raw = "Ask @{review-author}" },
			},
			reviewers = { { id = "review-author", name = "Duplicate" } },
		},
		conversation = { { author = { id = "conversation-author", name = "Conversation Author" } } },
		review_context = {
			mention_candidates = { { id = "review-author", name = "Review Author" } },
		},
	}
end

describe("Bitbucket mentions", function()
	it("formats display text without changing comments, tasks, or unknown mentions", function()
		local data = context()
		local original = vim.deepcopy(data)
		local format = mentions.formatter(data)

		assert.equal("Hi @Author and @{unknown}", format(data.data.comments[1].content_raw))
		assert.equal("Ask @Review Author", format(data.data.tasks[1].content_raw))
		assert.equal(
			"@Commenter @Task Author @Conversation Author @Reviewer",
			format("@{commenter} @{task-author} @{conversation-author} @{reviewer}")
		)
		assert.equal("Plain @username", format("Plain @username"))
		assert.same(original, data)
	end)

	it("keeps completion and reply mentions in the provider's original format", function()
		local data = context()
		local original = vim.deepcopy(data)
		local completion = mentions.for_pulls(data)

		assert.same({
			{ abbr = "@Author", menu = "mention", word = "@{author}" },
			{ abbr = "@Commenter", menu = "mention", word = "@{commenter}" },
			{ abbr = "@Conversation Author", menu = "mention", word = "@{conversation-author}" },
			{ abbr = "@Review Author", menu = "mention", word = "@{review-author}" },
			{ abbr = "@Reviewer", menu = "mention", word = "@{reviewer}" },
			{ abbr = "@Task Author", menu = "mention", word = "@{task-author}" },
		}, completion.complete(""))
		assert.same(
			{ { abbr = "@Reviewer", menu = "mention", word = "@{reviewer}" } },
			completion.complete("@REVIEWER")
		)
		assert.same({}, completion.complete("unknown"))
		assert.equal(6, completion.find_start("hello @rev"))
		assert.is_nil(completion.find_start("hello there"))
		assert.equal("@{author}", completion.format_mention({ id = "author", name = "Author" }))
		assert.equal("@nickname", completion.format_mention({ nickname = "nickname", name = "Name" }))
		assert.same(original, data)
	end)

	it("uses conversation authors and separately fetched reviewers without review data", function()
		local data = {
			pr = {},
			conversation = {
				{ author = { id = "commenter", name = "Commenter" }, content_raw = "Hi @{reviewer}" },
				{ author = { id = "task-author", name = "Task Author" }, is_task = true },
			},
			reviewers = { { id = "reviewer", name = "Reviewer" } },
		}
		local original = vim.deepcopy(data)
		local format = mentions.formatter(data)
		local completion = mentions.for_pulls(data)

		assert.equal("Hi @Reviewer", format(data.conversation[1].content_raw))
		assert.same({
			{ abbr = "@Commenter", menu = "mention", word = "@{commenter}" },
			{ abbr = "@Reviewer", menu = "mention", word = "@{reviewer}" },
			{ abbr = "@Task Author", menu = "mention", word = "@{task-author}" },
		}, completion.complete(""))
		assert.same(original, data)
	end)
end)
