local M = {
	issue = nil,
	raw_description = nil,
	---@type string|nil
	md_description = nil,
	description_loading = false,
	---@type table[]|nil
	custom_fields = nil,
	custom_fields_loading = false,
	---@type "markdown"|"raw"
	view_mode = "markdown",
	line_map = {},
}

function M.reset()
	M.issue = nil
	M.raw_description = nil
	M.md_description = nil
	M.description_loading = false
	M.custom_fields = nil
	M.custom_fields_loading = false
	M.view_mode = "markdown"
	M.line_map = {}
end

return M
