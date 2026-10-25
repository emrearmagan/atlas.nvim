local stack = require("atlas.pulls.stack")

describe("pull request stacks", function()
	local function stacked(entries)
		return {
			position = 2,
			size = 3,
			entries = entries or {
				{ position = 1, number = 10 },
				{ position = 2, number = 11 },
				{ position = 3, number = 12 },
			},
		}
	end

	it("detects stacked pull requests", function()
		assert.is_true(stack.is_stacked(stacked()))
		assert.is_false(stack.is_stacked(nil))
		assert.is_false(stack.is_stacked({ position = 1, size = 1 }))
	end)

	it("builds a stack indicator", function()
		assert.equal("⧉ 2/3", stack.indicator(stacked()))
		assert.is_nil(stack.indicator(nil))
		assert.is_nil(stack.indicator({ position = 1, size = 1 }))
	end)

	it("finds the next and previous stack entries", function()
		local next_entry = assert(stack.neighbor(stacked(), 1))
		local previous_entry = assert(stack.neighbor(stacked(), -1))

		assert.equal(12, next_entry.number)
		assert.equal(10, previous_entry.number)
	end)

	it("reports the stack boundaries", function()
		local top = stacked()
		top.position = 3
		local bottom = stacked()
		bottom.position = 1

		local _, top_reason = stack.neighbor(top, 1)
		local _, bottom_reason = stack.neighbor(bottom, -1)

		assert.equal("top", top_reason)
		assert.equal("bottom", bottom_reason)
	end)

	it("reports missing entries while details are loading", function()
		local _, reason = stack.neighbor({ position = 1, size = 2 }, 1)

		assert.equal("loading", reason)
	end)

	it("reports pull requests that are not part of a stack", function()
		local _, reason = stack.neighbor(nil, 1)

		assert.equal("not_stacked", reason)
	end)
end)
