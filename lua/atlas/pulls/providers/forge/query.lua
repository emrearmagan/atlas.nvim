local M = {}
local syntax = require("atlas.providers.forge.query")

---@type PullsStateFilter[]
local STATE_ORDER = { "open", "merged", "declined" }
---@type table<string, PullsStateFilter[]>
local QUERY_STATES = {
	open = { "open" },
	merged = { "merged" },
	declined = { "declined" },
	closed = { "merged", "declined" },
	all = STATE_ORDER,
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

---@param input string
---@return table|nil, string|nil
local function parse(input)
	local parsed, err = syntax.parse(input, { repo = "repo", type = "type" })
	if not parsed then
		return nil, err
	end
	if parsed.repo and not parsed.repo:match("^[^/%s]+/[^/%s]+$") then
		return nil, "Repository must be owner/repo"
	end
	if parsed.type and parsed.type:lower() ~= "pulls" then
		return nil, "Search type must be pulls"
	end
	local selected = {}
	for _, value in ipairs(parsed.states) do
		if value == "" then
			return nil, "Missing pull request state"
		end
		for state in value:lower():gmatch("[^,]+") do
			if not QUERY_STATES[state] then
				return nil, "Unknown pull request state: " .. state
			end
			vim.list_extend(selected, QUERY_STATES[state])
		end
	end
	parsed.states = #selected > 0 and ordered_states(selected) or nil
	return parsed, nil
end

---@param view AtlasGiteaPullsViewConfig|AtlasForgejoPullsViewConfig
---@return string, string, PullsStateFilter[], table
local function parts(view)
	-- Configured views and string bookmarks have always accepted query qualifiers.
	local parsed = parse(view.search or "") or { search = view.search or "", extra_params = {} }
	return vim.trim(parsed.repo or view.repo or ""),
		parsed.search,
		ordered_states(view._states or parsed.states),
		vim.tbl_extend("force", {}, view.extra_params or {}, parsed.extra_params)
end

---@param view AtlasPullsViewConfig
---@return string, PullsStateFilter[]
function M.resolve(view)
	---@cast view AtlasGiteaPullsViewConfig|AtlasForgejoPullsViewConfig
	local repo, search, states, extra_params = parts(view)
	local query = { repo ~= "" and ("repo:" .. repo) or "type:pulls" }
	for _, state in ipairs(states) do
		table.insert(query, "is:" .. state)
	end
	local extra_keys = vim.tbl_keys(extra_params)
	table.sort(extra_keys)
	for _, key in ipairs(extra_keys) do
		local value = extra_params[key]
		syntax.append(query, "param." .. key, value)
	end
	syntax.append(query, "search", search)
	return table.concat(query, " "), states
end

---@param view AtlasGiteaPullsViewConfig|AtlasForgejoPullsViewConfig
---@return AtlasGiteaPullsViewConfig|AtlasForgejoPullsViewConfig, string[]
function M.for_api(view)
	local repo, search, states, extra_params = parts(view)
	local api_view = vim.tbl_extend("force", {}, view, {
		repo = repo,
		search = search,
		extra_params = extra_params,
	})
	local statuses = {}
	for _, state in ipairs(states) do
		table.insert(statuses, state:upper())
	end
	return api_view, statuses
end

---@param view AtlasGiteaPullsViewConfig|AtlasForgejoPullsViewConfig
---@param input string
---@param default_states PullsStateFilter[]|nil
---@return boolean, string|nil
function M.apply(view, input, default_states)
	local parsed, err = parse(input)
	if not parsed then
		return false, err
	end
	view.repo = nil
	view.search = vim.trim(input)
	view.extra_params = nil
	view._states = ordered_states(parsed.states or default_states)
	view.current_repo = nil
	return true, nil
end

return M
