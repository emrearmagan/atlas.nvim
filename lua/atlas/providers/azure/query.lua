local M = {}

local API_STATES = { open = "active", merged = "completed", declined = "abandoned" }
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
		if field ~= "searchCriteria.status" and field ~= "$top" and field ~= "$skip" then
			append_field(parts, "param." .. field, extra_params[field])
		end
	end
	return table.concat(parts, " "), states
end

---@param view AtlasPullsViewConfig
---@return string[]
function M.api_states(view)
	local states = view._states or { "open" }
	if #states == 3 then
		return { "all" }
	end
	local api_states = {}
	for _, state in ipairs(states) do
		table.insert(api_states, API_STATES[state])
	end
	return api_states
end

return M
