local M = {}

local icons = require("atlas.ui.shared.icons")

---@param stack GitHubPullStack|nil
---@return boolean
function M.is_stacked(stack)
	return stack ~= nil and stack.position ~= nil and stack.size ~= nil and stack.size > 1
end

---@param stack GitHubPullStack|nil
---@return string|nil
function M.indicator(stack)
	if not M.is_stacked(stack) then
		return nil
	end
	---@cast stack GitHubPullStack
	return string.format("%s %d/%d", icons.get("stack"), stack.position, stack.size)
end

---@param stack GitHubPullStack
---@param direction 1|-1
---@return GitHubPullStackEntry|nil
function M.neighbor(stack, direction)
	local target = stack.position + direction
	for _, entry in ipairs(stack.entries or {}) do
		if entry.position == target then
			return entry
		end
	end
	return nil
end

return M
