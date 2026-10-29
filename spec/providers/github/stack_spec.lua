local stack = require("atlas.pulls.providers.github.stack")

describe("pull request stacks", function()
	local function stacked()
		return {
			position = 2,
			size = 3,
			entries = {
				{ position = 1, number = 10 },
				{ position = 2, number = 11 },
				{ position = 3, number = 12 },
			},
		}
	end

	it("finds the next and previous stack entries", function()
		local next_entry = assert(stack.neighbor(stacked(), 1))
		local previous_entry = assert(stack.neighbor(stacked(), -1))

		assert.equal(12, next_entry.number)
		assert.equal(10, previous_entry.number)
	end)

	it("returns nil at the stack boundaries", function()
		local top = stacked()
		top.position = 3
		local bottom = stacked()
		bottom.position = 1

		assert.is_nil(stack.neighbor(top, 1))
		assert.is_nil(stack.neighbor(bottom, -1))
	end)
end)
