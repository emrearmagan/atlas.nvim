local parser = require("atlas.core.git.diff_parser")

describe("diff_parser", function()
	describe("hunk header parsing", function()
		it("captures starts, counts, and function context", function()
			local raw = table.concat({
				"diff --git a/foo.lua b/foo.lua",
				"--- a/foo.lua",
				"+++ b/foo.lua",
				"@@ -10,4 +12,5 @@ function bar(x)",
				" context one",
				"-removed line",
				"+added line",
				" context two",
				" context three",
				"",
			}, "\n")

			local files = parser.parse(raw)
			assert.are.equal(1, #files)
			local h = files[1].hunks[1]
			assert.are.equal(10, h.old_start)
			assert.are.equal(4, h.old_count)
			assert.are.equal(12, h.new_start)
			assert.are.equal(5, h.new_count)
			assert.are.equal("function bar(x)", h.context)
			assert.are.equal("@@ -10,4 +12,5 @@ function bar(x)", h.header)
		end)

		it("treats omitted count as 1", function()
			local raw = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -5 +7 @@\n-old\n+new\n"
			local files = parser.parse(raw)
			local h = files[1].hunks[1]
			assert.are.equal(1, h.old_count)
			assert.are.equal(1, h.new_count)
		end)

		it("preserves count = 0 for empty side", function()
			local raw = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -5,0 +7,2 @@\n+a\n+b\n"
			local files = parser.parse(raw)
			local h = files[1].hunks[1]
			assert.are.equal(0, h.old_count)
			assert.are.equal(2, h.new_count)
		end)
	end)

	describe("per-line numbering", function()
		it("advances new_line only on adds, old_line only on removes", function()
			local raw = table.concat({
				"diff --git a/x b/x",
				"--- a/x",
				"+++ b/x",
				"@@ -10,3 +20,4 @@",
				" alpha",
				"-beta",
				"+gamma",
				"+delta",
			}, "\n")

			local files = parser.parse(raw)
			local lines = files[1].hunks[1].lines
			assert.are.equal(4, #lines)

			assert.are.equal("context", lines[1].kind)
			assert.are.equal(10, lines[1].old_line)
			assert.are.equal(20, lines[1].new_line)

			assert.are.equal("remove", lines[2].kind)
			assert.are.equal(11, lines[2].old_line)
			assert.is_nil(lines[2].new_line)

			assert.are.equal("add", lines[3].kind)
			assert.is_nil(lines[3].old_line)
			assert.are.equal(21, lines[3].new_line)

			assert.are.equal("add", lines[4].kind)
			assert.are.equal(22, lines[4].new_line)
		end)
	end)

	describe("content extraction", function()
		it("strips the leading +/-/space marker", function()
			local raw = table.concat({
				"diff --git a/x b/x",
				"--- a/x",
				"+++ b/x",
				"@@ -1,3 +1,3 @@",
				" context",
				"-removed",
				"+added",
				"",
			}, "\n")

			local lines = parser.parse(raw)[1].hunks[1].lines
			assert.are.equal("context", lines[1].content)
			assert.are.equal("removed", lines[2].content)
			assert.are.equal("added", lines[3].content)
		end)

		it("keeps the original text field with marker intact", function()
			local raw = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,1 +1,1 @@\n+added\n"
			local lines = parser.parse(raw)[1].hunks[1].lines
			assert.are.equal("+added", lines[1].text)
			assert.are.equal("added", lines[1].content)
		end)
	end)

	describe("additions / deletions", function()
		it("counts +/- lines per hunk", function()
			local raw = table.concat({
				"diff --git a/x b/x",
				"--- a/x",
				"+++ b/x",
				"@@ -1,5 +1,6 @@",
				" a",
				"-b",
				"-c",
				"+B",
				"+C",
				"+D",
				" e",
				"",
			}, "\n")

			local h = parser.parse(raw)[1].hunks[1]
			assert.are.equal(3, h.additions)
			assert.are.equal(2, h.deletions)
		end)

		it("treats context-only hunks as zero", function()
			local raw = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n a\n b\n"
			local h = parser.parse(raw)[1].hunks[1]
			assert.are.equal(0, h.additions)
			assert.are.equal(0, h.deletions)
		end)
	end)

	describe("file status", function()
		it("detects added files via 'new file mode'", function()
			local raw = table.concat({
				"diff --git a/new.lua b/new.lua",
				"new file mode 100644",
				"--- /dev/null",
				"+++ b/new.lua",
				"@@ -0,0 +1,2 @@",
				"+local M = {}",
				"+return M",
				"",
			}, "\n")

			local files = parser.parse(raw)
			assert.are.equal("added", files[1].status)
			assert.are.equal("new.lua", files[1].path)
		end)

		it("detects deleted files via 'deleted file mode'", function()
			local raw = table.concat({
				"diff --git a/gone.lua b/gone.lua",
				"deleted file mode 100644",
				"--- a/gone.lua",
				"+++ /dev/null",
				"@@ -1,2 +0,0 @@",
				"-local M = {}",
				"-return M",
				"",
			}, "\n")

			local files = parser.parse(raw)
			assert.are.equal("deleted", files[1].status)
			assert.are.equal("gone.lua", files[1].path)
		end)

		it("detects renames", function()
			local raw = table.concat({
				"diff --git a/old.lua b/new.lua",
				"similarity index 90%",
				"rename from old.lua",
				"rename to new.lua",
				"--- a/old.lua",
				"+++ b/new.lua",
				"@@ -1,2 +1,2 @@",
				" foo",
				"-bar",
				"+baz",
				"",
			}, "\n")

			local files = parser.parse(raw)
			assert.are.equal("renamed", files[1].status)
			assert.are.equal("old.lua", files[1].old_path)
			assert.are.equal("new.lua", files[1].path)
		end)

		it("defaults to modified for plain in-place changes", function()
			local raw = table.concat({
				"diff --git a/x.lua b/x.lua",
				"--- a/x.lua",
				"+++ b/x.lua",
				"@@ -1,1 +1,1 @@",
				"-a",
				"+b",
				"",
			}, "\n")

			assert.are.equal("modified", parser.parse(raw)[1].status)
		end)
	end)

	describe("multi-file / multi-hunk", function()
		it("returns one DiffFile per 'diff --git'", function()
			local raw = table.concat({
				"diff --git a/a.lua b/a.lua",
				"--- a/a.lua",
				"+++ b/a.lua",
				"@@ -1,1 +1,1 @@",
				"-1",
				"+1!",
				"diff --git a/b.lua b/b.lua",
				"--- a/b.lua",
				"+++ b/b.lua",
				"@@ -1,1 +1,1 @@",
				"-2",
				"+2!",
				"",
			}, "\n")

			local files = parser.parse(raw)
			assert.are.equal(2, #files)
			assert.are.equal("a.lua", files[1].path)
			assert.are.equal("b.lua", files[2].path)
		end)

		it("returns multiple hunks per file", function()
			local raw = table.concat({
				"diff --git a/x b/x",
				"--- a/x",
				"+++ b/x",
				"@@ -1,1 +1,1 @@",
				"-a",
				"+A",
				"@@ -50,2 +50,2 @@",
				" before",
				"-x",
				"+X",
				"",
			}, "\n")

			local hunks = parser.parse(raw)[1].hunks
			assert.are.equal(2, #hunks)
			assert.are.equal(1, hunks[1].new_start)
			assert.are.equal(50, hunks[2].new_start)
		end)
	end)

	describe("meta line", function()
		it("captures '\\ No newline at end of file' as kind=meta", function()
			local raw = table.concat({
				"diff --git a/x b/x",
				"--- a/x",
				"+++ b/x",
				"@@ -1,1 +1,1 @@",
				"-old",
				"+new",
				"\\ No newline at end of file",
			}, "\n")

			local lines = parser.parse(raw)[1].hunks[1].lines
			assert.are.equal(3, #lines)
			assert.are.equal("meta", lines[3].kind)
		end)
	end)

	describe("edge cases", function()
		it("returns empty list for empty input", function()
			assert.are.same({}, parser.parse(""))
		end)

		it("returns empty list for nil-ish (non-string) input", function()
			---@diagnostic disable-next-line: param-type-mismatch
			assert.are.same({}, parser.parse(nil))
		end)

		it("does not crash on a file block without hunks", function()
			local raw = table.concat({
				"diff --git a/empty.bin b/empty.bin",
				"new file mode 100644",
				"Binary files /dev/null and b/empty.bin differ",
				"",
			}, "\n")

			local files = parser.parse(raw)
			assert.are.equal(1, #files)
			assert.are.equal("added", files[1].status)
			assert.are.equal(0, #files[1].hunks)
		end)
	end)
end)
