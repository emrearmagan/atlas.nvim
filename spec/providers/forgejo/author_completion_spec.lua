local author_completion = require("atlas.providers.forgejo.completion.author")

local function words(completion, query)
	local result = {}
	for _, item in ipairs(completion.complete(query or "")) do
		table.insert(result, item.word)
	end
	return result
end

describe("Forgejo author completion", function()
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
			current_user = { account_id = "current" },
			issue = {
				reporter = { account_id = "reporter" },
				assignee = { account_id = "assignee" },
				assignees = { { account_id = "second-assignee" }, { account_id = "assignee" } },
			},
			comments = { { author = { account_id = "commenter" } } },
		})

		assert.same({ "@assignee", "@commenter", "@current", "@reporter", "@second-assignee" }, words(completion))
		assert.same({ "@reporter" }, words(completion, "@rep"))
		assert.equal("@forgejo-user", completion.format_mention({ account_id = "forgejo-user" }))
	end)

	it("completes pull request participants by username", function()
		local completion = author_completion.for_pulls({
			pr = {
				author = { username = "author" },
				assignees = { { username = "assignee" } },
				reviewers = { { username = "reviewer" } },
			},
			review_context = { authors = { { username = "review-author" } } },
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
			"@review-author",
			"@reviewer",
		}, words(completion))
		assert.equal("@forgejo-user", completion.format_mention({ username = "forgejo-user" }))
		assert.equal(6, completion.find_start("hello @for"))
	end)
end)
