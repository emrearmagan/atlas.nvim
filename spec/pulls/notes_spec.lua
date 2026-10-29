local notes = require("atlas.pulls.notes")

---@param start_line integer
---@param end_line integer
---@return AtlasNote
local function note(start_line, end_line)
	return { start_line = start_line, end_line = end_line }
end

---@param after integer
---@param count integer
---@return DiffHunk
local function inserted(after, count)
	return { old_start = after, old_count = 0, new_start = after + 1, new_count = count }
end

---@param first integer
---@param count integer
---@return DiffHunk
local function removed(first, count)
	return { old_start = first, old_count = count, new_start = first - 1, new_count = 0 }
end

---@param first integer
---@param count integer
---@return DiffHunk
local function changed(first, count)
	return { old_start = first, old_count = count, new_start = first, new_count = count }
end

describe("pulls.notes", function()
	describe("position", function()
		it("keeps a note when nothing changed", function()
			assert.are.same({ start_line = 12, end_line = 14, outdated = false }, notes.position(note(12, 14), {}))
		end)

		it("moves a note with lines added or removed above it", function()
			assert.are.same(
				{ start_line = 14, end_line = 16, outdated = false },
				notes.position(note(12, 14), { inserted(5, 2) })
			)
			assert.are.same(
				{ start_line = 10, end_line = 12, outdated = false },
				notes.position(note(12, 14), { removed(3, 2) })
			)
		end)

		it("ignores changes after the note", function()
			assert.are.same(
				{ start_line = 12, end_line = 14, outdated = false },
				notes.position(note(12, 14), { changed(15, 1) })
			)
		end)

		it("marks a note outdated when its lines changed", function()
			assert.are.same(
				{ start_line = 12, end_line = 12, outdated = true },
				notes.position(note(12, 14), { changed(14, 1) })
			)
			assert.are.same(
				{ start_line = 12, end_line = 12, outdated = true },
				notes.position(note(12, 14), { inserted(12, 1) })
			)
		end)
	end)
end)
