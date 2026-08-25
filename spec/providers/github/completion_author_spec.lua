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
				reporter = { account_id = "reporter", display_name = "Reporter Name" },
				assignee = { account_id = "reporter", display_name = "Duplicate" },
			},
			details = {
				assignees = {
					{ account_id = "z-assignee", display_name = "Zed" },
					{ account_id = "reporter", display_name = "Duplicate" },
				},
			},
			comments = {
				{ author = { account_id = "commenter", display_name = "Comment Author" } },
				{ author = { account_id = nil, display_name = "No Login" } },
			},
		})

		assert.same({ "@commenter", "@reporter", "@z-assignee" }, words(completion))
		assert.same({ "@reporter" }, words(completion, "@rep"))
		assert.equal("@commenter", completion.format_mention({ account_id = "commenter", display_name = "Name" }))
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
