local M = {
	raw_description = nil,
	---@type string|nil
	md_description = nil,
	description_loading = false,
	---@type "markdown"|"raw"
	view_mode = "markdown",
}

function M.reset()
	M.raw_description = nil
	M.md_description = nil
	M.description_loading = false
end

return M
