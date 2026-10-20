local reviewed = require("atlas.pulls.reviewed")

---@param path string
---@param old_blob string
---@param new_blob string
---@return AtlasDiffFile
local function file(path, old_blob, new_blob)
	return { path = path, status = "modified", binary = false, old_blob = old_blob, new_blob = new_blob }
end

describe("pulls.reviewed", function()
	describe("review_context", function()
		it("counts a file as reviewed while it is unchanged", function()
			assert.are.same(
				{ reviewed_files = { ["a.lua"] = true } },
				reviewed.review_context({ ["a.lua"] = "111:222" }, { file("a.lua", "111", "222") })
			)
		end)

		it("drops the mark once the file changed", function()
			assert.are.same(
				{ reviewed_files = {} },
				reviewed.review_context({ ["a.lua"] = "111:222" }, { file("a.lua", "111", "333") })
			)
			assert.are.same(
				{ reviewed_files = {} },
				reviewed.review_context({ ["a.lua"] = "111:222" }, { file("a.lua", "000", "222") })
			)
		end)

		it("ignores files without a mark and marks of files no longer in the diff", function()
			assert.are.same(
				{ reviewed_files = {} },
				reviewed.review_context({ ["gone.lua"] = "111:222" }, { file("a.lua", "111", "222") })
			)
		end)
	end)
end)
