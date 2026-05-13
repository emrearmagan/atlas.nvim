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

---@class DiffFile
---@field path string                   -- display path (new path, or old path for deletions)
---@field old_path string|nil           -- only set for renames
---@field status "added"|"deleted"|"modified"|"renamed"
---@field hunks DiffHunk[]

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

---@param raw string
---@return string[]
local function split_lines(raw)
	local out = {}
	raw = raw:gsub("\r\n", "\n")
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

	-- Rename: both sides set and differ
	if file.old_path and file.old_path ~= file.path and file.status == "modified" then
		file.status = "renamed"
	end
end

--------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------

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
---All git-internal lines (diff --git, index, mode, --- a/, +++ b/) are removedd here
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
		elseif cur_file then
			-- Lines inside a file block but before the first hunk (index, mode
			-- change lines, binary notice, etc.) — intentionally dropped.
		else
			-- Lines before any "diff --git" (shouldn't happen with Bitbucket, but
			-- guard against truncated/non-standard responses by attaching them to
			-- a synthetic file entry so nothing is silently lost).
			if #files == 0 and cur_file == nil then
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
			end
			if cur_hunk then
				table.insert(cur_hunk.lines, { text = line, kind = "context", content = line })
			end
		end
	end

	flush_file()
	return files
end

return M
