local mentions = require("atlas.providers.jira.mentions")

local function by_word(items)
	local result = {}
	for _, item in ipairs(items) do
		result[item.word] = item
	end
	return result
end

describe("Jira mentions", function()
	it("completes issue participants and comment authors", function()
		local completion = mentions.for_issues({
			issue = {
				assignee = { id = "assignee", name = "Assigned User" },
				reporter = { id = "reporter", name = "Reporter User" },
			},
			comments = {
				{ author = { id = "commenter", name = "Comment Author" } },
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
		local completion = mentions.for_issues({ issue = {}, comments = {} })

		assert.same({}, completion.complete(""))
		assert.equal(
			"[@Example User](atlas-mention:account-id)",
			completion.format_mention({ id = "account-id", name = "Example User" })
		)
	end)
end)
