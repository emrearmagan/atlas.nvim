local position = require("atlas.pulls.diff.shared.position")

local function document()
	return {
		old = { path = "old.lua", lines = { "one", "old two", "old three", "four", "five" } },
		new = { path = "new.lua", lines = { "one", "new two", "new three", "four", "five" } },
		changes = { { old_start = 2, old_count = 2, new_start = 2, new_count = 2 } },
		binary = false,
	}
end

describe("review positions", function()
	it("keeps single-line positions unchanged", function()
		assert.same({ path = "new.lua", old_path = "old.lua", to = 2 }, position.from_line(document(), "RIGHT", 2))
	end)

	it("normalizes new-side ranges", function()
		assert.same({
			path = "new.lua",
			old_path = "old.lua",
			start_to = 2,
			to = 3,
		}, position.from_range(document(), "RIGHT", 3, 2))
	end)

	it("constructs old-side ranges", function()
		assert.same({
			path = "new.lua",
			old_path = "old.lua",
			start_from = 2,
			from = 3,
		}, position.from_range(document(), "LEFT", 2, 3))
	end)

	it("keeps both coordinates for context ranges", function()
		assert.same({
			path = "new.lua",
			old_path = "old.lua",
			start_from = 4,
			start_to = 4,
			from = 5,
			to = 5,
		}, position.from_range(document(), "RIGHT", 4, 5))
	end)

	it("rejects invalid ranges", function()
		local value = document()
		value.binary = true
		assert.is_nil(position.from_range(value, "RIGHT", 2, 3))
		assert.is_nil(position.from_range(document(), "RIGHT", 2, 99))
	end)
end)
