local M = {}

---@param stack PullsStack|nil
---@return boolean
function M.is_stacked(stack)
	return stack ~= nil and stack.position ~= nil and stack.size ~= nil and stack.size > 1
end

---@param stack PullsStack|nil
---@return string|nil
function M.indicator(stack)
	if not M.is_stacked(stack) then
		return nil
	end
	return string.format("⧉ %d/%d", stack.position, stack.size)
end

---@param stack PullsStack|nil
---@param direction 1|-1
---@return PullsStackEntry|nil
---@return "not_stacked"|"loading"|"top"|"bottom"|nil
function M.neighbor(stack, direction)
	if not M.is_stacked(stack) then
		return nil, "not_stacked"
	end
	if stack.entries == nil or #stack.entries == 0 then
		return nil, "loading"
	end

	local target = stack.position + direction
	for _, entry in ipairs(stack.entries) do
		if entry.position == target then
			return entry, nil
		end
	end

	return nil, direction > 0 and "top" or "bottom"
end

return M
