local author_completion = require("atlas.providers.github.completion.author")

local function words(completion, query)
	local result = {}
	for _, item in ipairs(completion.complete(query or "")) do
		table.insert(result, item.word)
	end
	return result
end

describe("GitHub author completion", function()
	local original_trim

	before_each(function()
		original_trim = vim.trim
		vim.trim = function(value)
			return tostring(value):match("^%s*(.-)%s*$")
		end
	end)

	after_each(function()
		vim.trim = original_trim
	end)

	it("completes issue reporters, assignees, and comment authors by login", function()
		local completion = author_completion.for_issues({
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
		local completion = author_completion.for_pulls({
			pr = {
				author = { nickname = "pull-author", name = "Pull Author" },
			},
			details = { assignees = { { username = "assignee" } } },
			comments = { { author = { nickname = "commenter" } } },
			reviewers = { { nickname = "reviewer" } },
			review_context = { mention_candidates = { { nickname = "review-author" } } },
		})

		assert.same({ "@assignee", "@commenter", "@pull-author", "@review-author", "@reviewer" }, words(completion))
		assert.equal("@octocat", completion.format_mention({ nickname = "octocat", name = "Octo Cat" }))
		assert.equal(6, completion.find_start("hello @oct"))
	end)
end)
