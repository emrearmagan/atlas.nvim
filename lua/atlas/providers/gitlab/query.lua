local M = {}

local utils = require("atlas.core.utils")

local API_STATES = { open = "opened", merged = "merged", declined = "closed" }
local ATLAS_STATES = { opened = "open", merged = "merged", closed = "declined" }
local ALL_STATES = { "open", "merged", "declined" }
local ISSUE_STATES = { opened = true, closed = true, all = true }
local REVIEW_STATES = {
	UNREVIEWED = true,
	REVIEW_STARTED = true,
	REVIEWED = true,
	REQUESTED_CHANGES = true,
	APPROVED = true,
	UNAPPROVED = true,
}
local PULL_FIELDS = {
	"project",
	"group",
	"scope",
	"review_states",
	"labels",
	"milestone",
	"author_username",
	"assignee_username",
	"source_branch",
	"target_branch",
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
---@return string
local function build_query(state, view, fields)
	local parts = { "is:" .. state }
	for _, field in ipairs(fields) do
		local value = view[field]
		if field == "review_states" and value ~= nil then
			value = table.concat(value, ",")
		end
		if value ~= nil and value ~= "" then
			append_field(parts, (field:gsub("_username$", "")), value)
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
	local tokens = utils.split_tokens(input)

	local fields = {}
	local search = {}
	local states = {}
	for _, token in ipairs(tokens) do
		local key, value = token:match("^([^:%s]+):(.+)$")
		value = value and (value:match('^"(.*)"$') or value)
		local view_field = field_by_query[key]
		if key == "is" then
			table.insert(states, value)
		elseif key == "search" then
			table.insert(search, value)
		elseif view_field then
			fields[view_field] = value
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
end

---@param view AtlasGitLabPullsViewConfig
---@return PullsStateFilter[]
local function selected_states(view)
	if view._states then
		return view._states
	end

	local configured = view.state
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
	return build_query(table.concat(selected, ","), view, PULL_FIELDS), selected
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

---@param view AtlasGitLabPullsViewConfig
---@param input string
---@return boolean, string|nil
function M.apply(view, input)
	local parsed, states = parse_query(input, PULL_FIELD_BY_QUERY)
	local selected
	for _, state in ipairs(states) do
		selected = {}
		for status in state:gmatch("[^,]+") do
			if API_STATES[status] == nil then
				return false, "Unknown state: " .. status
			end
			table.insert(selected, status)
		end
	end
	if parsed.review_states ~= nil then
		parsed.review_states = vim.split(parsed.review_states, ",", { plain = true })
		for _, state in ipairs(parsed.review_states) do
			if not REVIEW_STATES[state] then
				return false, "Unknown review state: " .. state
			end
		end
	end
	apply_fields(view, parsed, PULL_FIELDS)
	view.state = nil
	view._states = selected
	return true, nil
end

---@param view IssuesViewConfig
---@return string
function M.issue_query(view)
	---@cast view AtlasGitLabIssuesViewConfig
	return build_query(view.state or "opened", view, ISSUE_FIELDS)
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
