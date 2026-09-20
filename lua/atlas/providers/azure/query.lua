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

---@param input string
---@return AtlasAzurePullsViewConfig|nil, string|nil
function M.parse(input)
	local tokens, current = {}, {}
	local quoted = false
	for i = 1, #input do
		local char = input:sub(i, i)
		if char == '"' then
			quoted = not quoted
			table.insert(current, char)
		elseif char:match("%s") and not quoted then
			if #current > 0 then
				table.insert(tokens, table.concat(current))
				current = {}
			end
		else
			table.insert(current, char)
		end
	end
	if #current > 0 then
		table.insert(tokens, table.concat(current))
	end

	---@type AtlasAzurePullsViewConfig
	local view = { name = "Search", layout = "compact", project = "", _states = { "open" }, extra_params = {} }
	for _, token in ipairs(tokens) do
		local key, value = token:match("^([^:%s]+):(.+)$")
		value = value and (value:match('^"(.*)"$') or value)
		local param = key and key:match("^param%.(.+)$")
		if key == "is" then
			view._states = {}
			for status in value:gmatch("[^,]+") do
				if API_STATES[status] == nil then
					return nil, "Unknown state: " .. status
				end
				---@cast status PullsStateFilter
				if not vim.list_contains(view._states, status) then
					table.insert(view._states, status)
				end
			end
			if #view._states == 0 then
				return nil, "Select at least one status"
			end
		elseif key == "project" or key == "repository" then
			view[key] = value
		elseif key == "scope" then
			if value ~= "all" and value ~= "assigned_to_me" and value ~= "created_by_me" then
				return nil, "Unknown scope: " .. value
			end
			view.scope = value
		elseif param and param ~= "searchCriteria.status" and param ~= "$top" and param ~= "$skip" then
			view.extra_params[param] = value
		else
			return nil, "Unsupported filter: " .. token
		end
	end
	if view.project == "" then
		return nil, "Project is required"
	end
	return view, nil
end

---@param view AtlasAzurePullsViewConfig
---@param input string
---@return boolean, string|nil
function M.apply(view, input)
	local parsed, err = M.parse(input)
	if parsed == nil then
		return false, err
	end
	for _, field in ipairs(FIELDS) do
		view[field] = parsed[field]
	end
	view._states = parsed._states
	view.extra_params = parsed.extra_params
	view.current_repo = nil
	return true, nil
end

return M
