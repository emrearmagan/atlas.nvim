local M = {
	issues = nil, ---@type table[]|"loading"|string|nil
	filter = "open", ---@type "open"|"closed"
	counts = nil, ---@type { open: integer, closed: integer }|nil
	last_slug = nil, ---@type string|nil
}

function M.reset()
	M.issues = nil
	M.filter = "open"
	M.counts = nil
	M.last_slug = nil
end

return M
