local parser = require("atlas.core.git.diff_parser")

describe("core.git.diff_parser", function()
	it("parses hunk ranges, omitted counts, empty sides and function context", function()
		for _, case in ipairs({
			{ "@@ -10,4 +12,5 @@ function bar(x)", { 10, 4, 12, 5 }, "function bar(x)" },
			{ "@@ -5 +7 @@", { 5, 1, 7, 1 }, "" },
			{ "@@ -5,0 +7,2 @@", { 5, 0, 7, 2 }, "" },
		}) do
			local hunk = parser.parse("diff --git a/x b/x\n" .. case[1])[1].hunks[1]
			assert.same(case[2], { hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count })
			assert.equals(case[3], hunk.context)
			assert.equals(case[1], hunk.header)
		end
	end)

	it("numbers context, removals and additions without counting metadata as content", function()
		local hunk = parser.parse(table.concat({
			"diff --git a/x b/x",
			"--- a/x",
			"+++ b/x",
			"@@ -10,2 +20,3 @@",
			" alpha",
			"-beta",
			"+gamma",
			"+delta",
			"\\ No newline at end of file",
		}, "\n"))[1].hunks[1]

		assert.same({
			{ kind = "context", content = "alpha", text = " alpha", old_line = 10, new_line = 20 },
			{ kind = "remove", content = "beta", text = "-beta", old_line = 11 },
			{ kind = "add", content = "gamma", text = "+gamma", new_line = 21 },
			{ kind = "add", content = "delta", text = "+delta", new_line = 22 },
			{ kind = "meta", content = "\\ No newline at end of file", text = "\\ No newline at end of file" },
		}, hunk.lines)
		assert.equals(2, hunk.additions)
		assert.equals(1, hunk.deletions)
	end)

	it("recognizes file status and paths", function()
		for _, case in ipairs({
			{
				"diff --git a/new.lua b/new.lua\nnew file mode 100644\n--- /dev/null\n+++ b/new.lua",
				"added",
				"new.lua",
			},
			{
				"diff --git a/gone.lua b/gone.lua\ndeleted file mode 100644\n--- a/gone.lua\n+++ /dev/null",
				"deleted",
				"gone.lua",
			},
			{
				"diff --git a/old.lua b/new.lua\nrename from old.lua\nrename to new.lua",
				"renamed",
				"new.lua",
				"old.lua",
			},
			{
				"diff --git a/x.lua b/x.lua\n--- a/x.lua\n+++ b/x.lua\n@@ -1 +1 @@\n-old\n+new",
				"modified",
				"x.lua",
			},
		}) do
			local file = parser.parse(case[1])[1]
			assert.equals(case[2], file.status)
			assert.equals(case[3], file.path)
			if case[4] then
				assert.equals(case[4], file.old_path)
			end
		end
	end)

	it("keeps separate files and their hunks", function()
		local files = parser.parse(table.concat({
			"diff --git a/a.lua b/a.lua",
			"--- a/a.lua",
			"+++ b/a.lua",
			"@@ -1 +1 @@",
			"-1",
			"+1!",
			"diff --git a/b.lua b/b.lua",
			"--- a/b.lua",
			"+++ b/b.lua",
			"@@ -1 +1 @@",
			"-2",
			"+2!",
		}, "\n"))

		assert.equals(2, #files)
		assert.equals("a.lua", files[1].path)
		assert.equals("b.lua", files[2].path)
		assert.equals(1, #files[1].hunks)
		assert.equals(1, #files[2].hunks)
	end)

	it("keeps multiple hunks in one file", function()
		local hunks = parser.parse(table.concat({
			"diff --git a/x b/x",
			"@@ -1 +1 @@",
			"-a",
			"+A",
			"@@ -50,2 +50,2 @@",
			" before",
			"-x",
			"+X",
		}, "\n"))[1].hunks

		assert.equals(2, #hunks)
		assert.equals(1, hunks[1].new_start)
		assert.equals(50, hunks[2].new_start)
	end)

	it("returns no files for an empty diff", function()
		assert.same({}, parser.parse(""))
	end)

	it("preserves binary files without text hunks", function()
		local files = parser.parse(table.concat({
			"diff --git a/empty.bin b/empty.bin",
			"new file mode 100644",
			"Binary files /dev/null and b/empty.bin differ",
		}, "\n"))

		assert.equals(1, #files)
		assert.equals("added", files[1].status)
		assert.same({}, files[1].hunks)
	end)
end)
