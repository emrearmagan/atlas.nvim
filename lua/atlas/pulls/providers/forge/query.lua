local M = {}

---@type PullsStateFilter[]
local STATE_ORDER = { "open", "merged", "declined" }
---@type table<string, PullsStateFilter[]>
local QUERY_STATES = {
	["is:open"] = { "open" },
	["is:merged"] = { "merged" },
	["is:declined"] = { "declined" },
	["is:closed"] = { "merged", "declined" },
	["is:all"] = STATE_ORDER,
}

---@param values PullsStateFilter[]|nil
---@return PullsStateFilter[]
local function ordered_states(values)
	local selected = {}
	for _, state in ipairs(values or {}) do
		selected[state] = true
	end
	local states = {}
	for _, state in ipairs(STATE_ORDER) do
		if selected[state] then
			table.insert(states, state)
		end
	end
	return #states > 0 and states or { "open" }
end

---@param view AtlasGiteaPullsViewConfig|AtlasForgejoPullsViewConfig
---@return string, string, PullsStateFilter[]
local function parts(view)
	local repo = vim.trim(view.repo or "")
	local search = {}
	local query_states

	for token in tostring(view.search or ""):gmatch("%S+") do
		local lower = token:lower()
		local states = QUERY_STATES[lower]
		if states then
			query_states = query_states or {}
			vim.list_extend(query_states, states)
		elseif lower ~= "type:pulls" then
			local qualifier, value = token:match("^([^:]+):(.+)$")
			if qualifier and qualifier:lower() == "repo" and value:match("^[^/%s]+/[^/%s]+$") then
				repo = value
			else
				table.insert(search, token)
			end
		end
	end

	return repo, table.concat(search, " "), ordered_states(view._states or query_states)
end

---@param view AtlasPullsViewConfig
---@return string, PullsStateFilter[]
function M.resolve(view)
	---@cast view AtlasGiteaPullsViewConfig|AtlasForgejoPullsViewConfig
	local repo, search, states = parts(view)
	local query = { repo ~= "" and ("repo:" .. repo) or "type:pulls" }
	for _, state in ipairs(states) do
		table.insert(query, "is:" .. state)
	end
	local extra_keys = vim.tbl_keys(view.extra_params or {})
	table.sort(extra_keys)
	for _, key in ipairs(extra_keys) do
		local value = view.extra_params[key]
		if value ~= nil and value ~= "" then
			table.insert(query, key .. ":" .. tostring(value))
		end
	end
	if search ~= "" then
		table.insert(query, search)
	end
	return table.concat(query, " "), states
end

---@param view AtlasGiteaPullsViewConfig|AtlasForgejoPullsViewConfig
---@return AtlasGiteaPullsViewConfig|AtlasForgejoPullsViewConfig, string[]
function M.for_api(view)
	local repo, search, states = parts(view)
	local api_view = vim.tbl_extend("force", {}, view, { repo = repo, search = search })
	local statuses = {}
	for _, state in ipairs(states) do
		table.insert(statuses, state:upper())
	end
	return api_view, statuses
end

return M
