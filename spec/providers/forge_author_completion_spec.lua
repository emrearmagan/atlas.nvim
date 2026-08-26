local author_completion = require("atlas.providers.forge.completion.author")

local function words(completion, query)
	local result = {}
	for _, item in ipairs(completion.complete(query or "")) do
		table.insert(result, item.word)
	end
	return result
end

describe("Forge author completion", function()
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

	it("completes issue participants by login", function()
		local completion = author_completion.for_issues({
			issue = {
				reporter = { account_id = "reporter" },
				assignee = { account_id = "assignee" },
			},
			details = {
				assignees = { { account_id = "second-assignee" }, { account_id = "assignee" } },
			},
			comments = { { author = { account_id = "commenter" } } },
		})

		assert.same({ "@assignee", "@commenter", "@reporter", "@second-assignee" }, words(completion))
		assert.same({ "@reporter" }, words(completion, "@rep"))
		assert.equal("@forge-user", completion.format_mention({ account_id = "forge-user" }))
	end)

	it("completes every pull request participant source", function()
		local completion = author_completion.for_pulls({
			pr = {
				author = { username = "author" },
				reviewers = { { username = "pr-reviewer" } },
			},
			details = { assignees = { { username = "assignee" } } },
			review_context = { mention_candidates = { { username = "review-author" } } },
			reviewers = { { username = "context-reviewer" } },
			comments = { { author = { username = "commenter" } } },
			conversation = { { author = { username = "conversation-author" } } },
		})

		assert.same({
			"@assignee",
			"@author",
			"@commenter",
			"@context-reviewer",
			"@conversation-author",
			"@pr-reviewer",
			"@review-author",
		}, words(completion))
		assert.equal("@forge-user", completion.format_mention({ username = "forge-user" }))
		assert.equal(6, completion.find_start("hello @forge.user"))
	end)
end)
