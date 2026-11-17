local suggestions = require("atlas.pulls.diff.suggestions")

---@param body string
---@param inline PullsInlineCommentPosition|nil
---@param overrides table|nil
---@return PullsComment
local function comment(body, inline, overrides)
	local value = { id = 1, body = body, inline = inline or { path = "lua/a.lua", to = 24 } }
	for key, field in pairs(overrides or {}) do
		value[key] = field
	end
	return value
end

describe("pulls.diff.suggestions", function()
	describe("format", function()
		it("fences the lines as a suggestion", function()
			assert.are.equal(
				"```suggestion\nlocal a = 1\nlocal b = 2\n```",
				suggestions.format({ "local a = 1", "local b = 2" }, "github")
			)
		end)

		it("reaches up to the first line on GitLab", function()
			assert.are.equal(
				"```suggestion:-1+0\nlocal a = 1\nlocal b = 2\n```",
				suggestions.format({ "local a = 1", "local b = 2" }, "gitlab")
			)
		end)
	end)

	describe("parse", function()
		it("replaces the commented line", function()
			local value = comment("Use a constant\n```suggestion\nlocal x = 1\n```")
			assert.are.same(
				{ comment = value, path = "lua/a.lua", first = 24, last = 24, lines = { "local x = 1" } },
				suggestions.parse(value)
			)
		end)

		it("replaces the commented range", function()
			local value = comment("```suggestion\nlocal x = 1\n```", { path = "lua/a.lua", start_to = 22, to = 24 })
			local suggestion = assert(suggestions.parse(value))
			assert.are.same({ 22, 24 }, { suggestion.first, suggestion.last })
		end)

		it("reads the range from a GitLab fence", function()
			local value = comment("```suggestion:-2+1\nlocal x = 1\nlocal y = 2\n```")
			local suggestion = assert(suggestions.parse(value))
			assert.are.same({ 22, 25 }, { suggestion.first, suggestion.last })
			assert.are.same({ "local x = 1", "local y = 2" }, suggestion.lines)
		end)

		it("reads bodies with Windows line endings", function()
			local suggestion = assert(suggestions.parse(comment("Fix\r\n```suggestion\r\nlocal x = 1\r\n```")))
			assert.are.same({ "local x = 1" }, suggestion.lines)
		end)

		it("deletes the lines when the suggestion is empty", function()
			local suggestion = assert(suggestions.parse(comment("```suggestion\n```")))
			assert.are.same({}, suggestion.lines)
		end)

		it("skips comments without a suggestion", function()
			assert.is_nil(suggestions.parse(comment("Looks good")))
			assert.is_nil(suggestions.parse(comment("```lua\nlocal x = 1\n```")))
		end)

		it("skips comments that are not on a line", function()
			assert.is_nil(suggestions.parse(comment("```suggestion\nlocal x = 1\n```", { path = "lua/a.lua" })))
		end)

		it("skips comments that are closed", function()
			local body = "```suggestion\nlocal x = 1\n```"
			assert.is_nil(suggestions.parse(comment(body, nil, { deleted = true })))
			assert.is_nil(suggestions.parse(comment(body, nil, { outdated = true })))
			assert.is_nil(suggestions.parse(comment(body, nil, { state = "RESOLVED" })))
		end)
	end)
end)
