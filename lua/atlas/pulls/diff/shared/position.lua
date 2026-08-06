local M = {}

---@alias AtlasReviewSide "LEFT"|"RIGHT"

---@param inline PullsInlineCommentPosition|nil
---@return AtlasReviewSide|nil side
---@return integer|nil line
function M.location(inline)
	if not inline then
		return nil, nil
	end
	if type(inline.to) == "number" then
		return "RIGHT", inline.to
	end
	if type(inline.from) == "number" then
		return "LEFT", inline.from
	end
	return nil, nil
end

---@param document AtlasReviewDocument
---@param side AtlasReviewSide
---@param line integer
---@param target_line_count integer
---@return integer line
---@return boolean above
function M.opposite_line(document, side, line, target_line_count)
	local offset = 0
	for _, change in ipairs(document.changes) do
		local start = side == "LEFT" and change.old_start or change.new_start
		local count = side == "LEFT" and change.old_count or change.new_count
		local other_start = side == "LEFT" and change.new_start or change.old_start
		local other_count = side == "LEFT" and change.new_count or change.old_count
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

---@param document AtlasReviewDocument
---@param side AtlasReviewSide
---@param line integer
---@return boolean
function M.is_changed(document, side, line)
	for _, change in ipairs(document.changes) do
		local start = side == "LEFT" and change.old_start or change.new_start
		local count = side == "LEFT" and change.old_count or change.new_count
		if count > 0 and line >= start and line < start + count then
			return true
		end
	end
	return false
end

---@param document AtlasReviewDocument
---@param side AtlasReviewSide
---@param line integer
---@return PullsInlineCommentPosition|nil
---@return string|nil
function M.from_line(document, side, line)
	local source = side == "LEFT" and document.old or document.new
	local other = side == "LEFT" and document.new or document.old
	if document.binary then
		return nil
	end
	if line < 1 or line > #source.lines then
		return nil, "The selected line is outside the file"
	end

	local result = {
		path = document.new.path,
		old_path = document.old.path,
		from = side == "LEFT" and line or nil,
		to = side == "RIGHT" and line or nil,
	}
	if not M.is_changed(document, side, line) then
		local opposite = M.opposite_line(document, side, line, #other.lines)
		if side == "LEFT" then
			result.to = opposite
		else
			result.from = opposite
		end
	end
	return result, nil
end

---@param document AtlasReviewDocument
---@param side AtlasReviewSide
---@param start_line integer
---@param end_line integer
---@return PullsInlineCommentPosition|nil
---@return string|nil
function M.from_range(document, side, start_line, end_line)
	start_line, end_line = math.min(start_line, end_line), math.max(start_line, end_line)
	local first, err = M.from_line(document, side, start_line)
	if not first then
		return nil, err
	end
	local last
	last, err = M.from_line(document, side, end_line)
	if not last then
		return nil, err
	end
	if start_line ~= end_line then
		local first_side = M.location(first)
		local last_side = M.location(last)
		if first_side ~= last_side then
			return nil, "The selected lines cannot be represented as one review range"
		end
		last.start_from = first.from
		last.start_to = first.to
	end
	return last, nil
end

return M
