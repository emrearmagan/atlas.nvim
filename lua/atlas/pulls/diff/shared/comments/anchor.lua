local M = {}

---@class AtlasReviewCommentAnchor
---@field line integer
---@field above boolean|nil

---@param document AtlasNativeDiffDocument|nil
---@param side "LEFT"|"RIGHT"
---@param line integer
---@param target_line_count integer
---@return integer line
---@return boolean above
function M.opposite_line(document, side, line, target_line_count)
	if not document then
		return 1, false
	end
	local offset = 0
	for _, hunk in ipairs(document.file.hunks) do
		local start = side == "LEFT" and hunk.old_start or hunk.new_start
		local count = side == "LEFT" and hunk.old_count or hunk.new_count
		local other_start = side == "LEFT" and hunk.new_start or hunk.old_start
		local other_count = side == "LEFT" and hunk.new_count or hunk.old_count
		if line < start or (count == 0 and line == start) then
			break
		end
		if count > 0 and line < start + count then
			local target = other_start + (other_count > 0 and math.min(line - start, other_count - 1) or 0)
			if target < 1 then
				return 1, true
			end
			return math.min(target_line_count, target), false
		end
		offset = offset + other_count - count
	end
	local target = line + offset
	if target < 1 then
		return 1, true
	end
	return math.min(target_line_count, target), false
end

---@param hunk DiffHunk
---@param side "LEFT"|"RIGHT"
---@param source_line integer
---@return string[] lines
---@return integer|nil anchor_index
local function hunk_lines(hunk, side, source_line)
	local lines, anchor_index = {}, nil
	for _, diff_line in ipairs(hunk.lines) do
		local line = side == "LEFT" and diff_line.old_line or diff_line.new_line
		if line then
			table.insert(lines, diff_line.content)
			if line == source_line then
				anchor_index = #lines
			end
		end
	end
	return lines, anchor_index
end

---@param lines string[]
---@param pattern string[]
---@param start integer
---@return boolean
local function matches_at(lines, pattern, start)
	if start < 1 or start + #pattern - 1 > #lines then
		return false
	end
	for index, item in ipairs(pattern) do
		if lines[start + index - 1] ~= item then
			return false
		end
	end
	return true
end

---@param lines string[]
---@param pattern string[]
---@return integer|nil start
local function unique_start(lines, pattern)
	if #pattern == 0 then
		return nil
	end
	local has_text = false
	for _, item in ipairs(pattern) do
		has_text = has_text or item:find("%S") ~= nil
	end
	if not has_text then
		return nil
	end

	local result
	for start = 1, #lines - #pattern + 1 do
		if matches_at(lines, pattern, start) then
			if result then
				return nil
			end
			result = start
		end
	end
	return result
end

---@param target string[]
---@param source string[]
---@param anchor_index integer
---@return AtlasReviewCommentAnchor|nil
local function exact_hunk_anchor(target, source, anchor_index)
	local start = unique_start(target, source)
	return start and { line = start + anchor_index - 1 } or nil
end

-- Use unique surrounding context to place a deleted line in the current file.
---@param target string[]
---@param source string[]
---@param anchor_index integer
---@return AtlasReviewCommentAnchor|nil
local function deleted_hunk_anchor(target, source, anchor_index)
	local context = {}
	for index, item in ipairs(source) do
		if index ~= anchor_index then
			table.insert(context, item)
		end
	end
	local start = unique_start(target, context)
	if not start then
		return nil
	end
	if anchor_index <= #context then
		return { line = start + anchor_index - 1, above = true }
	end
	return { line = start + #context - 1, above = false }
end

---@param comment PullsComment
---@param side "LEFT"|"RIGHT"
---@param target string[] current full-file lines for this side
---@return AtlasReviewCommentAnchor|nil
function M.resolve(comment, side, target)
	local inline = comment.inline
	local source_line = inline and (side == "LEFT" and inline.from or inline.to) or nil
	if not source_line then
		return nil
	end

	local hunk = comment.inline_hunk
	if hunk then
		local source, anchor_index = hunk_lines(hunk, side, source_line)
		if anchor_index then
			local anchor = exact_hunk_anchor(target, source, anchor_index)
				or deleted_hunk_anchor(target, source, anchor_index)
			if anchor then
				return anchor
			end
			if
				comment.state ~= "OUTDATED"
				and source_line >= 1
				and source_line <= #target
				and target[source_line] == source[anchor_index]
			then
				return { line = source_line }
			end
			if comment.state ~= "OUTDATED" then
				return nil
			end
		end
	end

	if comment.state == "OUTDATED" then
		-- Keep unmatched outdated threads visible at the top.
		return { line = 1, above = true }
	end
	if source_line >= 1 and source_line <= #target then
		return { line = source_line }
	end
	return nil
end

return M
