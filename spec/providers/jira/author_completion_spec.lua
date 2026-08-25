local author_completion = require("atlas.providers.jira.completion.author")

local function by_word(items)
	local result = {}
	for _, item in ipairs(items) do
		result[item.word] = item
	end
	return result
end

describe("Jira author completion", function()
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

	it("completes issue participants and comment authors", function()
		local completion = author_completion.for_issues({
			issue = {
				assignee = { account_id = "assignee", display_name = "Assigned User" },
				reporter = { account_id = "reporter", display_name = "Reporter User" },
			},
			comments = {
				{ author = { account_id = "commenter", display_name = "Comment Author" } },
			},
		})

		local matches = by_word(completion.complete(""))
		assert.equal("@Assigned User", matches["[@Assigned User](atlas-mention:assignee)"].abbr)
		assert.equal("@Reporter User", matches["[@Reporter User](atlas-mention:reporter)"].abbr)
		assert.equal("@Comment Author", matches["[@Comment Author](atlas-mention:commenter)"].abbr)
		assert.same({
			abbr = "@Reporter User",
			menu = "mention",
			word = "[@Reporter User](atlas-mention:reporter)",
		}, completion.complete("@rep")[1])
	end)

	it("formats mentions with no issue participants", function()
		local completion = author_completion.for_issues({ issue = {}, comments = {} })

		assert.same({}, completion.complete(""))
		assert.equal(
			"[@Example User](atlas-mention:account-id)",
			completion.format_mention({ account_id = "account-id", display_name = "Example User" })
		)
	end)
end)
