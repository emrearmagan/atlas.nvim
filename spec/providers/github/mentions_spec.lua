local mentions = require("atlas.providers.github.mentions")

local function words(completion, query)
	local result = {}
	for _, item in ipairs(completion.complete(query or "")) do
		table.insert(result, item.word)
	end
	return result
end

describe("GitHub mentions", function()
	it("completes issue reporters, assignees, and comment authors by login", function()
		local completion = mentions.for_issues({
			issue = {
				reporter = { username = "reporter", name = "Reporter Name" },
				assignee = { username = "reporter", name = "Duplicate" },
			},
			details = {
				assignees = {
					{ username = "z-assignee", name = "Zed" },
					{ username = "reporter", name = "Duplicate" },
				},
			},
			comments = {
				{ author = { username = "commenter", name = "Comment Author" } },
				{ author = { username = nil, name = "No Login" } },
			},
		})

		assert.same({ "@commenter", "@reporter", "@z-assignee" }, words(completion))
		assert.same({ "@reporter" }, words(completion, "@rep"))
		assert.equal("@commenter", completion.format_mention({ username = "commenter", name = "Name" }))
	end)

	it("preserves pull request completion sources and mention formatting", function()
		local context = {
			pr = {
				author = { nickname = "pull-author", name = "Pull Author" },
			},
			details = { assignees = { { username = "assignee" } } },
			data = {
				comments = { { author = { nickname = "commenter" } } },
				tasks = { { author = { nickname = "task-author" } } },
				reviewers = { { nickname = "reviewer" } },
			},
			review_context = { mention_candidates = { { nickname = "review-author" } } },
		}
		local original = vim.deepcopy(context)
		local completion = mentions.for_pulls(context)

		assert.same(
			{ "@assignee", "@commenter", "@pull-author", "@review-author", "@reviewer", "@task-author" },
			words(completion)
		)
		assert.equal("@octocat", completion.format_mention({ nickname = "octocat", name = "Octo Cat" }))
		assert.equal(6, completion.find_start("hello @oct"))
		assert.same(original, context)
	end)

	it("uses conversation authors and separately fetched reviewers without review data", function()
		local context = {
			pr = {},
			conversation = {
				{ author = { nickname = "commenter" } },
				{ author = { nickname = "task-author" }, is_task = true },
			},
			reviewers = { { nickname = "reviewer" } },
		}
		local original = vim.deepcopy(context)
		local completion = mentions.for_pulls(context)

		assert.same({ "@commenter", "@reviewer", "@task-author" }, words(completion))
		assert.same(original, context)
	end)
end)
