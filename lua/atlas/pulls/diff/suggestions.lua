local M = {}

-- Returns the lines fenced as a suggestion for a review comment.
---@param lines string[]
---@param provider string
---@return string
function M.format(lines, provider)
	local fence = "suggestion"
	if provider == "gitlab" then
		-- GitLab comments sit on the last line, so reach up to the first.
		fence = string.format("suggestion:-%d+0", #lines - 1)
	end
	return string.format("```%s\n%s\n```", fence, table.concat(lines, "\n"))
end

return M
