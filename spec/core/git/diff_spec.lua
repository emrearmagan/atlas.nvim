local diff = require("atlas.core.git.diff")

---@return DiffHunk
local function hunk(old_start, old_count, new_start, new_count)
	return { old_start = old_start, old_count = old_count, new_start = new_start, new_count = new_count }
end

describe("core.git.diff", function()
	it("moves a range by the lines added or removed before it", function()
		for _, case in ipairs({
			{ {}, 12, 14 },
			{ { hunk(5, 0, 6, 2) }, 14, 16 },
			{ { hunk(3, 2, 2, 0) }, 10, 12 },
			{ { hunk(15, 1, 15, 1) }, 12, 14 },
		}) do
			assert.same({ case[2], case[3] }, { diff.map_range(case[1], "LEFT", 12, 14) })
		end
	end)

	it("returns nothing when the range itself changed", function()
		for _, hunks in ipairs({ { hunk(14, 1, 14, 1) }, { hunk(12, 0, 13, 1) } }) do
			assert.same({}, { diff.map_range(hunks, "LEFT", 12, 14) })
		end
	end)
end)
