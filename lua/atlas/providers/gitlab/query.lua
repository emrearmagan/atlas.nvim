local M = {}

local API_STATES = { open = "opened", merged = "merged", declined = "closed" }
local ATLAS_STATES = { opened = "open", merged = "merged", closed = "declined" }
local ALL_STATES = { "open", "merged", "declined" }

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
	local parts = { "is:" .. table.concat(selected, ",") }
	for _, field in ipairs({
		"project",
		"group",
		"scope",
		"labels",
		"milestone",
		"author_username",
		"assignee_username",
	}) do
		local value = view[field]
		if value ~= nil and value ~= "" then
			table.insert(parts, string.format("%s:%s", field:gsub("_username$", ""), tostring(value)))
		end
	end
	if view.search and view.search ~= "" then
		table.insert(parts, tostring(view.search))
	end
	return table.concat(parts, " "), selected
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

return M
