local stack = require("atlas.pulls.providers.github.stack")

describe("pull request stacks", function()
	it("finds the next and previous stack entries and nothing past the ends", function()
		for _, case in ipairs({
			{ 2, 1, { position = 3, number = 12 } },
			{ 2, -1, { position = 1, number = 10 } },
			{ 3, 1 },
			{ 1, -1 },
		}) do
			local stacked = {
				position = case[1],
				size = 3,
				entries = {
					{ position = 1, number = 10 },
					{ position = 2, number = 11 },
					{ position = 3, number = 12 },
				},
			}

			assert.same(case[3], stack.neighbor(stacked, case[2]))
		end
	end)
end)
