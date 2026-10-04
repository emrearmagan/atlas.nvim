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

	local function flush_file()
		if cur_file then
			finalise_file(cur_file)
			table.insert(files, cur_file)
			cur_file = nil
		end
		cur_hunk = nil
	end

	for _, line in ipairs(split_lines(raw)) do
		-- ---/+++ are source lines while the current hunk still expects content.
		local in_hunk = cur_hunk
			and (
				old_cursor < cur_hunk.old_start + cur_hunk.old_count
				or new_cursor < cur_hunk.new_start + cur_hunk.new_count
			)
		if line:match("^diff %-%-git ") then
			flush_file()
			cur_file = { path = "", status = "modified", hunks = {} }
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
		elseif not in_hunk and line:match("^%-%-%- ") then
			cur_file = cur_file or { path = "", status = "modified", hunks = {} }
			-- Extract old path; /dev/null means the file is new
			local path = line:match("^%-%-%- a/(.+)$") or line:match("^%-%-%- (.+)$")
			if path and path ~= "/dev/null" then
				cur_file.old_path = path
			end
		elseif not in_hunk and line:match("^%+%+%+ ") then
			-- Extract new path; /dev/null means the file is deleted
			if cur_file then
				local path = line:match("^%+%+%+ b/(.+)$") or line:match("^%+%+%+ (.+)$")
				if path and path ~= "/dev/null" then
					cur_file.path = path
				end
				-- /dev/null on +++ side is handled in finalise_file
			end
		elseif line:match("^@@ ") then
			cur_file = cur_file or { path = "", status = "modified", hunks = {} }
			local old_start, old_count, new_start, new_count, context =
				line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@ ?(.*)$")
			cur_hunk = {
				header = line,
				context = context or "",
				old_start = tonumber(old_start) or 0,
				old_count = tonumber(old_count) or (old_count == "" and 1 or 0),
				new_start = tonumber(new_start) or 0,
				new_count = tonumber(new_count) or (new_count == "" and 1 or 0),
				additions = 0,
				deletions = 0,
				lines = {},
			}
			table.insert(cur_file.hunks, cur_hunk)
			old_cursor, new_cursor = cur_hunk.old_start, cur_hunk.new_start
		elseif cur_hunk then
			local marker = line:sub(1, 1)
			local entry = { text = line }
			if marker == "+" then
				entry.kind = "add"
				entry.content = line:sub(2)
				entry.new_line = new_cursor
				new_cursor = new_cursor + 1
				cur_hunk.additions = cur_hunk.additions + 1
			elseif marker == "-" then
				entry.kind = "remove"
				entry.content = line:sub(2)
				entry.old_line = old_cursor
				old_cursor = old_cursor + 1
				cur_hunk.deletions = cur_hunk.deletions + 1
			elseif line:match("^\\ ") then
				entry.kind = "meta" -- "\ No newline at end of file"
				entry.content = line
			else
				entry.kind = "context"
				entry.content = marker == " " and line:sub(2) or line
				entry.old_line = old_cursor
				entry.new_line = new_cursor
				old_cursor = old_cursor + 1
				new_cursor = new_cursor + 1
			end
			table.insert(cur_hunk.lines, entry)
		elseif not cur_file and #files == 0 then
			-- Preserve headerless comment previews without inventing a file path.
			cur_file = { path = "(unknown)", status = "modified", hunks = {} }
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
			table.insert(cur_file.hunks, cur_hunk)
		end
	end

	flush_file()
	return files
end

---@param raw string
---@return DiffHunk|nil
function M.parse_hunk(raw)
	local file = M.parse(raw)[1]
	return file and file.hunks[1] or nil
end

return M
