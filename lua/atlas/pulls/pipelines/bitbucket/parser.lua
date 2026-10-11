local M = {}

---@param log PullsLog
---@return PullsLogLine[]
function M.parse(log)
	return log.lines
end

return M
