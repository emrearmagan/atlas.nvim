local M = {
	issues = nil, ---@type table[]|"loading"|string|nil
	filter = "open", ---@type "open"|"closed"
	counts = nil, ---@type { open: integer, closed: integer }|nil
	last_path = nil, ---@type string|nil
}

function M.reset()
	M.issues = nil
	M.filter = "open"
	M.counts = nil
	M.last_path = nil
end

---@return boolean
function M.any_loading()
	return M.issues == "loading"
end

return M
