-- Use vim.diff on Neovim < 0.12.
---@diagnostic disable-next-line: deprecated
local diff = vim.text and vim.text.diff or vim.diff

local M = {}

-- Find where a line lands on the other side of the diff.
---@param hunks integer[][]
---@param side "LEFT"|"RIGHT"
---@param line integer
---@return integer, integer[]|nil
function M.map_line(hunks, side, line)
	local offset = 0
	local source, target = side == "LEFT" and 1 or 3, side == "LEFT" and 3 or 1

	for _, hunk in ipairs(hunks) do
		local start, count = hunk[source], hunk[source + 1]
		local other_start, other_count = hunk[target], hunk[target + 1]

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

---@param old string
---@param new string
---@return integer[][] split_hunks
function M.compute_split(old, new)
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
	local split_hunks = diff(text.old, text.new, options)
	---@cast split_hunks integer[][]
	return split_hunks
end

---@param old string
---@param new string
---@return integer[][] hunks, integer[][] split_hunks
function M.compute(old, new)
	local hunks = diff(old, new, { result_type = "indices", algorithm = "histogram" })
	---@cast hunks integer[][]
	return hunks, M.compute_split(old, new)
end

return M
