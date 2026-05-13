---@class PullsFilesTabState
---@field diff DiffFile[]|"loading"|string|nil
---@field diffstat PullsDiffstatEntry[]|"loading"|string|nil
---@field diffstat_collapsed boolean
---@field collapsed_hunks table<string|number, boolean>
local M = {
	diff = nil,
	diffstat = nil,
	diffstat_collapsed = true,
	collapsed_hunks = {},
}

function M.reset()
	M.diff = nil
	M.diffstat_collapsed = true
	M.collapsed_hunks = {}
end

---@return boolean
function M.any_loading()
	return M.diff == "loading" or M.diffstat == "loading"
end

return M
