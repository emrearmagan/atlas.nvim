local M = {}

local FIELDS = { "project", "repository", "scope" }

---@param parts string[]
---@param key string
---@param value any
local function append_field(parts, key, value)
	value = tostring(value)
	if value:find("%s") then
		value = '"' .. value .. '"'
	end
	table.insert(parts, key .. ":" .. value)
end

---@param view AtlasPullsViewConfig
---@return string, PullsStateFilter[]
function M.query(view)
	---@cast view AtlasAzurePullsViewConfig
	local states = view._states or { "open" }
	local parts = { "is:" .. table.concat(states, ",") }
	for _, field in ipairs(FIELDS) do
		local value = view[field]
		if value ~= nil and value ~= "" then
			append_field(parts, field, value)
		end
	end

	local extra_params = view.extra_params or {}
	local extra_fields = vim.tbl_keys(extra_params)
	table.sort(extra_fields)
	for _, field in ipairs(extra_fields) do
		append_field(parts, "param." .. field, extra_params[field])
	end

	if view.search and view.search ~= "" then
		append_field(parts, "search", view.search)
	end
	return table.concat(parts, " "), states
end

return M
