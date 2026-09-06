local M = {}

local API_STATES = { open = "opened", merged = "merged", declined = "closed" }
local ATLAS_STATES = { opened = "open", merged = "merged", closed = "declined" }
local ALL_STATES = { "open", "merged", "declined" }
local ISSUE_STATES = { opened = true, closed = true, all = true }
local PULL_FIELDS = {
	"project",
	"group",
	"scope",
	"labels",
	"milestone",
	"author_username",
	"assignee_username",
	"sort",
	"order_by",
}
local ISSUE_FIELDS = {
	"project",
	"scope",
	"labels",
	"milestone",
	"author_username",
	"assignee_username",
	"sort",
	"order_by",
}

---@param fields string[]
---@return table<string, string>
local function fields_by_query(fields)
	local result = {}
	for _, field in ipairs(fields) do
		result[(field:gsub("_username$", ""))] = field
	end
	return result
end

local PULL_FIELD_BY_QUERY = fields_by_query(PULL_FIELDS)
local ISSUE_FIELD_BY_QUERY = fields_by_query(ISSUE_FIELDS)

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

---@param state string
---@param view table
---@param fields string[]
---@param excluded_params table<string, boolean>
---@return string
local function build_query(state, view, fields, excluded_params)
	local parts = { "is:" .. state }
	for _, field in ipairs(fields) do
		local value = view[field]
		if value ~= nil and value ~= "" then
			append_field(parts, (field:gsub("_username$", "")), value)
		end
	end

	local extra_params = view.extra_params or {}
	local extra_fields = vim.tbl_keys(extra_params)
	table.sort(extra_fields)
	for _, field in ipairs(extra_fields) do
		if not excluded_params[field] then
			append_field(parts, "param." .. field, extra_params[field])
		end
	end

	if view.search and view.search ~= "" then
		append_field(parts, "search", view.search)
	end
	return table.concat(parts, " ")
end

---@param input string
---@param field_by_query table<string, string>
---@return table, string[]
local function parse_query(input, field_by_query)
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

	local fields = {}
	local search = {}
	local states = {}
	for _, token in ipairs(tokens) do
		local key, value = token:match("^([^:%s]+):(.+)$")
		value = value and (value:match('^"(.*)"$') or value)
		local extra_field = key and key:match("^param%.(.+)$")
		local view_field = field_by_query[key]
		if key == "is" then
			table.insert(states, value)
		elseif key == "search" then
			table.insert(search, value)
		elseif view_field then
			fields[view_field] = value
		elseif extra_field then
			fields.extra_params = fields.extra_params or {}
			fields.extra_params[extra_field] = value
		else
			table.insert(search, token)
		end
	end
	if #search > 0 then
		fields.search = table.concat(search, " ")
	end
	return fields, states
end

---@param view table
---@param parsed table
---@param fields string[]
local function apply_fields(view, parsed, fields)
	for _, field in ipairs(fields) do
		view[field] = parsed[field]
	end
	view.search = parsed.search
	view.extra_params = parsed.extra_params
end

---@param view AtlasGitLabPullsViewConfig
---@return PullsStateFilter[]
local function selected_states(view)
	if view._states then
		return view._states
	end

	local configured = view.extra_params and view.extra_params.state
	if configured == "all" then
		return ALL_STATES
	end
	return { ATLAS_STATES[configured] or "open" }
end

---@param view AtlasPullsViewConfig
---@return string, PullsStateFilter[]
function M.query(view)
	---@cast view AtlasGitLabPullsViewConfig
	local selected = selected_states(view)
	return build_query(table.concat(selected, ","), view, PULL_FIELDS, { state = true, page = true, per_page = true }),
		selected
end

---@param view AtlasPullsViewConfig
---@return ("opened"|"closed"|"merged"|"all")[]
function M.api_states(view)
	---@cast view AtlasGitLabPullsViewConfig
	local selected = selected_states(view)
	if #selected == 3 then
		return { "all" }
	end
	local api_states = {}
	for _, state in ipairs(selected) do
		table.insert(api_states, API_STATES[state])
	end
	return api_states
end

---@param input string
---@return AtlasGitLabPullsViewConfig|nil, string|nil
function M.parse(input)
	local parsed, states = parse_query(input, PULL_FIELD_BY_QUERY)
	local view = { name = "Search", layout = "compact" }
	apply_fields(view, parsed, PULL_FIELDS)
	for _, state in ipairs(states) do
		view._states = {}
		for status in state:gmatch("[^,]+") do
			if API_STATES[status] == nil then
				return nil, "Unknown state: " .. status
			end
			table.insert(view._states, status)
		end
	end
	return view, nil
end

---@param view AtlasGitLabPullsViewConfig
---@param input string
---@return boolean, string|nil
function M.apply(view, input)
	local parsed, err = M.parse(input)
	if parsed == nil then
		return false, err
	end
	apply_fields(view, parsed, PULL_FIELDS)
	view._states = parsed._states
	return true, nil
end

---@param view IssuesViewConfig
---@return string
function M.issue_query(view)
	---@cast view AtlasGitLabIssuesViewConfig
	return build_query(view.state or "opened", view, ISSUE_FIELDS, { page = true, per_page = true })
end

---@param view AtlasGitLabIssuesViewConfig
---@param input string
---@return boolean, string|nil
function M.apply_issue(view, input)
	local parsed, states = parse_query(input, ISSUE_FIELD_BY_QUERY)
	for _, state in ipairs(states) do
		if not ISSUE_STATES[state] then
			return false, "Unknown state: " .. state
		end
	end
	apply_fields(view, parsed, ISSUE_FIELDS)
	view.state = states[#states]
	return true, nil
end

return M
