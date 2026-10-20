local diff_parser = require("atlas.core.git.diff_parser")
local git = require("atlas.core.git")
local request_scope = require("atlas.core.requests")

-- Use vim.diff on Neovim < 0.12.
---@diagnostic disable-next-line: deprecated
local vim_diff = vim.text and vim.text.diff or vim.diff

local M = {}

---@class AtlasDiffRange
---@field root string
---@field base_revision string
---@field head_revision string

---@class AtlasDiffFile
---@field path string
---@field old_path string|nil
---@field status "added"|"deleted"|"modified"|"renamed"|"copied"|"type_changed"
---@field additions integer|nil
---@field deletions integer|nil
---@field binary boolean
---@field old_blob string
---@field new_blob string

local statuses = {
	A = "added",
	D = "deleted",
	M = "modified",
	R = "renamed",
	C = "copied",
	T = "type_changed",
}

local function run(root, args, on_done)
	return git.run(args, { cwd = root, text = false }, function(result)
		if result.code ~= 0 then
			on_done(nil, vim.trim(result.stderr))
			return
		end

		on_done(result.stdout, nil)
	end)
end

---@param root string
---@param revision string
---@param path string
---@param on_done fun(content: string|nil, err: string|nil)
---@return { cancel: fun() }
function M.read(root, revision, path, on_done)
	-- TODO: Submodules point to commits, not file contents. Show their hashes instead.
	return run(root, { "cat-file", "blob", revision .. ":" .. path }, on_done)
end

-- Returns changed lines between two revisions per file. Files without changes are left out.
-- for example: in greet.lua a line was added after line 1, and line 4 was replaced by line 5:
--   {
--     ["greet.lua"] = {
--       { old_start = 1, old_count = 0, new_start = 2, new_count = 1 },
--       { old_start = 4, old_count = 1, new_start = 5, new_count = 1 },
--     },
--   }
---@param root string
---@param base string
---@param head string
---@param on_done fun(hunks: table<string, DiffHunk[]>|nil, err: string|nil)
---@return { cancel: fun() }
function M.hunks(root, base, head, on_done)
	return run(root, {
		"-c",
		"core.quotePath=false",
		"diff",
		"-U0",
		"--histogram",
		"--no-indent-heuristic",
		"--no-renames",
		"--no-color",
		"--no-ext-diff",
		"--no-textconv",
		base,
		head,
		"--",
	}, function(output, err)
		if not output then
			on_done(nil, err)
			return
		end

		local hunks = {}
		for _, file in ipairs(diff_parser.parse(output)) do
			hunks[file.path] = file.hunks
		end
		on_done(hunks, nil)
	end)
end

---@param root string
---@param base string
---@param head string
---@param on_done fun(result: { range: AtlasDiffRange, files: AtlasDiffFile[] }|nil, err: string|nil)
---@return { cancel: fun() }
function M.load(root, base, head, on_done)
	local requests = request_scope.new()

	requests.run(function(done)
		return run(root, { "merge-base", base, head }, done)
	end, function(output, err)
		if not output then
			on_done(nil, err)
			return
		end

		local merge_base = vim.trim(output)
		local function diff(format, done)
			return run(root, {
				"diff",
				format,
				"-z",
				"--no-abbrev",
				"--find-renames",
				"--no-color",
				"--no-ext-diff",
				"--no-textconv",
				merge_base,
				head,
				"--",
			}, done)
		end

		requests.all({
			files = function(done)
				return diff("--raw", done)
			end,
			stats = function(done)
				return diff("--numstat", done)
			end,
		}, function(outputs, errors)
			local diff_err = errors.files or errors.stats
			if diff_err then
				on_done(nil, diff_err)
				return
			end

			-- Paths can contain tabs or newlines, so Git separates them with NULs.
			local status_fields = vim.split(outputs.files, "\0", { plain = true, trimempty = true })
			---@type AtlasDiffFile[]
			local files = {}
			---@type table<string, AtlasDiffFile>
			local files_by_path = {}
			local index = 1

			while index <= #status_fields do
				local old_blob, new_blob, status = status_fields[index]:match("^:%d+ %d+ (%x+) (%x+) (%a)")
				local path = status_fields[index + 1]
				local old_path
				index = index + 2

				if status == "R" or status == "C" then
					old_path = path
					path = status_fields[index]
					index = index + 1
				end

				local file = {
					path = path,
					old_path = old_path,
					status = statuses[status],
					binary = false,
					old_blob = old_blob,
					new_blob = new_blob,
				}
				files[#files + 1] = file
				files_by_path[path] = file
			end

			local stat_fields = vim.split(outputs.stats, "\0", { plain = true, trimempty = true })
			index = 1

			while index <= #stat_fields do
				local additions, deletions, path = stat_fields[index]:match("^([^\t]+)\t([^\t]+)\t(.*)$")
				index = index + 1

				-- Renames put the old and new paths in the next two fields.
				if path == "" then
					path = stat_fields[index + 1]
					index = index + 2
				end

				local file = files_by_path[path]
				file.additions = tonumber(additions)
				file.deletions = tonumber(deletions)
				file.binary = additions == "-"
			end

			on_done({ range = { root = root, base_revision = merge_base, head_revision = head }, files = files }, nil)
		end)
	end)

	return { cancel = requests.cancel }
end

-- Find where a line lands on the other side of the diff.
---@param hunks DiffHunk[]
---@param side "LEFT"|"RIGHT"
---@param line integer
---@return integer, DiffHunk|nil
function M.map_line(hunks, side, line)
	local offset = 0

	for _, hunk in ipairs(hunks) do
		local start, count, other_start, other_count = hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count
		if side == "RIGHT" then
			start, count, other_start, other_count = other_start, other_count, start, count
		end

		if line < start or (count == 0 and line == start) then
			break
		end

		if count > 0 and line < start + count then
			local relative = other_count > 0 and math.min(line - start, other_count - 1) or 0
			return other_start + relative, hunk
		end

		offset = offset + other_count - count
	end

	return line + offset
end

---@param hunks DiffHunk[]
---@param side "LEFT"|"RIGHT"
---@param start_line integer
---@param end_line integer
---@return integer|nil start_line
---@return integer|nil end_line
function M.map_range(hunks, side, start_line, end_line)
	for _, hunk in ipairs(hunks) do
		local start, count = hunk.old_start, hunk.old_count
		if side == "RIGHT" then
			start, count = hunk.new_start, hunk.new_count
		end
		local changed = count > 0 and start <= end_line and start + count > start_line
		local inserted = count == 0 and start >= start_line and start < end_line
		if changed or inserted then
			return nil, nil
		end
	end
	return (M.map_line(hunks, side, start_line)), (M.map_line(hunks, side, end_line))
end

---@param hunks DiffHunk[]
---@param pane integer
---@param line integer
---@return integer
function M.display_line(hunks, pane, line)
	local row = line
	-- Filler rows make different line numbers line up across the panes.
	for _, hunk in ipairs(hunks) do
		local start, count, other_count = hunk.old_start, hunk.old_count, hunk.new_count
		if pane ~= 1 then
			start, count, other_count = hunk.new_start, hunk.new_count, hunk.old_count
		end
		if line < start + count or (count == 0 and line == start) then
			break
		end
		row = row + math.max(0, other_count - count)
	end
	return row
end

---@param indices integer[][]
---@return DiffHunk[]
local function named(indices)
	return vim.tbl_map(function(hunk)
		return { old_start = hunk[1], old_count = hunk[2], new_start = hunk[3], new_count = hunk[4] }
	end, indices)
end

---@param old string
---@param new string
---@return DiffHunk[] hunks, DiffHunk[] split_hunks
function M.compute(old, new)
	local hunks = vim_diff(old, new, { result_type = "indices", algorithm = "histogram" })
	---@cast hunks integer[][]

	local flags = {}
	for _, option in ipairs(vim.opt.diffopt:get()) do
		flags[option] = true
	end

	local options = {
		result_type = "indices",
		algorithm = vim.o.diffopt:match("algorithm:([^,]+)") or "myers",
		linematch = tonumber(vim.o.diffopt:match("linematch:(%d+)")),
		indent_heuristic = flags["indent-heuristic"],
		ignore_whitespace = flags.iwhiteall,
		ignore_whitespace_change = flags.iwhite,
		ignore_whitespace_change_at_eol = flags.iwhiteeol,
		ignore_blank_lines = flags.iblank,
	}

	local text = { old = old, new = new }
	for side, content in pairs(text) do
		-- Native diff compares buffer lines with a final newline.
		if content ~= "" and content:sub(-1) ~= "\n" then
			content = content .. "\n"
		end
		if flags.icase then
			content = vim.fn.tolower(content)
		end
		text[side] = content
	end

	-- This follows Neovim's built-in diff, not a custom diffexpr.
	local split_hunks = vim_diff(text.old, text.new, options)
	---@cast split_hunks integer[][]
	return named(hunks), named(split_hunks)
end

return M
