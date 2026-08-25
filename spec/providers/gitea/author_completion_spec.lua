local author_completion = require("atlas.providers.gitea.completion.author")

local function words(items)
	local result = {}
	for _, item in ipairs(items) do
		table.insert(result, item.word)
	end
	return result
end

describe("Gitea author completion", function()
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
			current_user = { account_id = "current", display_name = "Current User" },
			issue = {
				reporter = { account_id = "reporter", display_name = "Reporter" },
				assignee = { account_id = "alice", display_name = "Alice" },
				assignees = {
					{ account_id = "alice", display_name = "Alice" },
					{ account_id = "zoe", display_name = "Zoe" },
				},
			},
			comments = { { author = { account_id = "commenter", display_name = "Commenter" } } },
		})

		assert.same({ "@alice", "@commenter", "@current", "@reporter", "@zoe" }, words(completion.complete("")))
		assert.same({ "@commenter" }, words(completion.complete("@com")))
		assert.equal("@gitea-user", completion.format_mention({ account_id = "gitea-user" }))
	end)

	it("preserves pull request completion sources", function()
		local completion = author_completion.for_pulls({
			pr = {
				author = { username = "author" },
				assignees = { { username = "assignee" } },
				reviewers = { { username = "pr-reviewer" } },
			},
			reviewers = { { username = "reviewer" } },
			review_context = { authors = { { username = "review-author" } } },
			comments = { { author = { username = "commenter" } } },
			conversation = { { author = { username = "conversation" } } },
		})

		assert.same({
			"@assignee",
			"@author",
			"@commenter",
			"@conversation",
			"@pr-reviewer",
			"@review-author",
			"@reviewer",
		}, words(completion.complete("")))
		assert.equal("@gitea-user", completion.format_mention({ username = "gitea-user" }))
		assert.equal(6, completion.find_start("hello @gitea.user"))
	end)
end)
