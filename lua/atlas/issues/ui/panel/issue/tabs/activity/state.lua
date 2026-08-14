local M = {
	issue = nil, ---@type Issue|nil
	entries = nil, ---@type IssueActivityEntry[]|nil
	error = nil, ---@type string|nil
	is_loading = false,
	line_map = {},
}

function M.reset()
	M.issue = nil
	M.entries = nil
	M.error = nil
	M.is_loading = false
	M.line_map = {}
end

function M.any_loading()
	return M.is_loading
end

return M
