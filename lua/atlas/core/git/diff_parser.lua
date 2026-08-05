local M = {}

---@class DiffLine
---@field kind "add"|"remove"|"context"|"meta"
---@field text string                  -- raw line, leading +/-/space preserved
---@field content string                -- text without the leading +/-/space marker
---@field old_line integer|nil          -- nil on "add" and "meta"
---@field new_line integer|nil          -- nil on "remove" and "meta"

---@class DiffHunk
---@field header string                 -- raw "@@ -x,y +a,b @@ <context>" line
---@field context string                -- text after the second @@ (e.g. function name)
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field additions integer
---@field deletions integer
---@field lines DiffLine[]

---@alias DiffFileStatus "added"|"deleted"|"modified"|"renamed"|"type_changed"|"unknown"

---@class DiffFile
---@field path string                   -- display path (new path, or old path for deletions)
---@field old_path string|nil           -- only set for renames
---@field status DiffFileStatus
---@field hunks DiffHunk[]
---@field additions integer|nil         -- optional total when supplied without hunks
---@field deletions integer|nil          -- optional total when supplied without hunks

-- Helpers

---@param raw string
---@return string[]
local function split_lines(raw)
	local out = {}
	raw = raw:gsub("\r\n", "\n")
	if raw:sub(-1) == "\n" then
		raw = raw:sub(1, -2)
	end
	for line in (raw .. "\n"):gmatch("(.-)\n") do
		table.insert(out, line)
	end
	return out
end

---@param file DiffFile
local function finalise_file(file)
	-- Deleted file: path was /dev/null on +++ side, use old_path
	if file.path == "" and file.old_path then
		file.path = file.old_path
		file.old_path = nil
		file.status = "deleted"
	end

	if file.old_path == file.path then
		file.old_path = nil
	elseif file.old_path and file.status == "modified" then
		file.status = "renamed"
	end
end

-- Public

-- Example
--   raw unified diff:
--     diff --git a/foo.lua b/foo.lua
--     --- a/foo.lua
--     +++ b/foo.lua
--     @@ -10,3 +20,4 @@ function bar(x)
--      alpha
--     -beta
--     +gamma
--     +delta
--
--   output (DiffFile[]):
--     [1] = {
--       path = "foo.lua",
--       old_path = nil,
--       status = "modified",
--       hunks = {
--         [1] = {
--           header     = "@@ -10,3 +20,4 @@ function bar(x)",
--           context    = "function bar(x)",
--           old_start  = 10, old_count = 3,
--           new_start  = 20, new_count = 4,
--           additions  = 2, deletions = 1,
--           lines = {
--             { kind = "context", content = "alpha", old_line = 10, new_line = 20,  text = " alpha" },
--             { kind = "remove",  content = "beta",  old_line = 11, new_line = nil, text = "-beta"  },
--             { kind = "add",     content = "gamma", old_line = nil, new_line = 21, text = "+gamma" },
--             { kind = "add",     content = "delta", old_line = nil, new_line = 22, text = "+delta" },
--           },
--         },
--       },
--     }

---Parse a raw unified diff string into a structured representation.
---All git-internal lines (diff --git, index, mode, --- a/, +++ b/) are removed here.
---@param raw string
---@return DiffFile[]
function M.parse(raw)
	if type(raw) ~= "string" or raw == "" then
		return {}
	end

	local files = {}
	---@type DiffFile|nil
	local cur_file = nil
	---@type DiffHunk|nil
	local cur_hunk = nil
	local old_cursor = 0
	local new_cursor = 0

	local function flush_hunk()
		if cur_hunk and cur_file then
			table.insert(cur_file.hunks, cur_hunk)
			cur_hunk = nil
		end
	end

	local function flush_file()
		flush_hunk()
		if cur_file then
			finalise_file(cur_file)
			table.insert(files, cur_file)
			cur_file = nil
		end
	end

	for _, line in ipairs(split_lines(raw)) do
		if line:match("^diff %-%-git ") then
			flush_file()
			cur_file = { path = "", old_path = nil, status = "modified", hunks = {} }
		elseif line:match("^new file mode") then
			if cur_file then
				cur_file.status = "added"
			end
		elseif line:match("^deleted file mode") then
			if cur_file then
				cur_file.status = "deleted"
			end
		elseif line:match("^rename from ") then
			if cur_file then
				cur_file.old_path = line:match("^rename from (.+)$")
				cur_file.status = "renamed"
			end
		elseif line:match("^rename to ") then
			if cur_file then
				cur_file.path = line:match("^rename to (.+)$")
			end
		elseif line:match("^%-%-%- ") then
			-- Extract old path; /dev/null means the file is new
			if cur_file then
				local p = line:match("^%-%-%- a/(.+)$") or line:match("^%-%-%- (.+)$")
				if p and p ~= "/dev/null" then
					cur_file.old_path = p
				end
			end
		elseif line:match("^%+%+%+ ") then
			-- Extract new path; /dev/null means the file is deleted
			if cur_file then
				local p = line:match("^%+%+%+ b/(.+)$") or line:match("^%+%+%+ (.+)$")
				if p and p ~= "/dev/null" then
					cur_file.path = p
				end
				-- /dev/null on +++ side is handled in finalise_file
			end
		elseif line:match("^@@ ") then
			flush_hunk()
			if cur_file then
				local oa, ob, na, nb, ctx = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@ ?(.*)$")
				local old_start = tonumber(oa) or 0
				local old_count = tonumber(ob)
				if old_count == nil or old_count == 0 then
					old_count = ob == "" and 1 or 0
				end
				local new_start = tonumber(na) or 0
				local new_count = tonumber(nb)
				if new_count == nil or new_count == 0 then
					new_count = nb == "" and 1 or 0
				end
				cur_hunk = {
					header = line,
					context = ctx or "",
					old_start = old_start,
					old_count = old_count,
					new_start = new_start,
					new_count = new_count,
					additions = 0,
					deletions = 0,
					lines = {},
				}
				old_cursor = old_start
				new_cursor = new_start
			end
		elseif cur_hunk then
			local kind
			local entry = { text = line }
			if line:match("^%+") then
				kind = "add"
				entry.content = line:sub(2)
				entry.new_line = new_cursor
				new_cursor = new_cursor + 1
				cur_hunk.additions = cur_hunk.additions + 1
			elseif line:match("^%-") then
				kind = "remove"
				entry.content = line:sub(2)
				entry.old_line = old_cursor
				old_cursor = old_cursor + 1
				cur_hunk.deletions = cur_hunk.deletions + 1
			elseif line:match("^\\ ") then
				kind = "meta" -- "\ No newline at end of file"
				entry.content = line
			else
				kind = "context"
				entry.content = line:sub(1, 1) == " " and line:sub(2) or line
				entry.old_line = old_cursor
				entry.new_line = new_cursor
				old_cursor = old_cursor + 1
				new_cursor = new_cursor + 1
			end
			entry.kind = kind
			table.insert(cur_hunk.lines, entry)
		elseif not cur_file and #files == 0 then
			-- Lines before any "diff --git" (shouldn't happen with Bitbucket, but
			-- guard against truncated/non-standard responses by attaching them to
			-- a synthetic file entry so nothing is silently lost).
			cur_file = { path = "(unknown)", old_path = nil, status = "modified", hunks = {} }
			cur_hunk = {
				header = "",
				context = "",
				old_start = 0,
				old_count = 0,
				new_start = 0,
				new_count = 0,
				additions = 0,
				deletions = 0,
				lines = {},
			}
			table.insert(cur_hunk.lines, { text = line, kind = "context", content = line })
		end
	end

	flush_file()
	return files
end

---Return a clipped hunk centered on one old/new line, with a header and counts
---that describe the clipped lines rather than the original hunk.
---@param hunk DiffHunk
---@param side "old"|"new"
---@param line integer
---@param context_lines integer|nil
---@return DiffHunk
function M.window_hunk(hunk, side, line, context_lines)
	local anchor
	for index, diff_line in ipairs(hunk.lines) do
		if (side == "old" and diff_line.old_line == line) or (side == "new" and diff_line.new_line == line) then
			anchor = index
			break
		end
	end
	if anchor == nil then
		return hunk
	end

	local context = math.max(0, context_lines or 3)
	local first = math.max(1, anchor - context)
	local last = math.min(#hunk.lines, anchor + context)
	if first == 1 and last == #hunk.lines then
		return hunk
	end

	local old_start, new_start = hunk.old_start, hunk.new_start
	for index = 1, first - 1 do
		local diff_line = hunk.lines[index]
		if diff_line.kind == "context" or diff_line.kind == "remove" then
			old_start = old_start + 1
		end
		if diff_line.kind == "context" or diff_line.kind == "add" then
			new_start = new_start + 1
		end
	end

	local lines = {}
	local old_count, new_count, additions, deletions = 0, 0, 0, 0
	for index = first, last do
		local diff_line = hunk.lines[index]
		table.insert(lines, diff_line)
		if diff_line.kind == "context" or diff_line.kind == "remove" then
			old_count = old_count + 1
		end
		if diff_line.kind == "context" or diff_line.kind == "add" then
			new_count = new_count + 1
		end
		if diff_line.kind == "add" then
			additions = additions + 1
		elseif diff_line.kind == "remove" then
			deletions = deletions + 1
		end
	end
	if old_count == 0 then
		old_start = math.max(0, old_start - 1)
	end
	if new_count == 0 then
		new_start = math.max(0, new_start - 1)
	end

	local header = string.format("@@ -%d,%d +%d,%d @@", old_start, old_count, new_start, new_count)
	if hunk.context ~= "" then
		header = header .. " " .. hunk.context
	end
	return {
		header = header,
		context = hunk.context,
		old_start = old_start,
		old_count = old_count,
		new_start = new_start,
		new_count = new_count,
		additions = additions,
		deletions = deletions,
		lines = lines,
	}
end

---@param file DiffFile|nil
---@param side "old"|"new"
---@param line integer
---@return DiffHunk|nil
function M.find_hunk(file, side, line)
	if not file then
		return nil
	end
	for _, hunk in ipairs(file.hunks or {}) do
		local start = side == "old" and hunk.old_start or hunk.new_start
		local count = side == "old" and hunk.old_count or hunk.new_count
		if line >= start and line < start + count then
			return M.window_hunk(hunk, side, line)
		end
	end
	return nil
end

return M
