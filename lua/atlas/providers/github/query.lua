local M = {}

local STATE_QUERIES = {
	open = "is:open",
	merged = "is:merged",
	declined = "is:closed -is:merged",
}

---@param states PullsStateFilter[]
---@return string
local function state_query(states)
	local qualifiers = {}
	for _, state in ipairs(states) do
		table.insert(qualifiers, STATE_QUERIES[state])
	end
	local query = table.concat(qualifiers, " OR ")
	return #qualifiers > 1 and ("(" .. query .. ")") or query
end

---@type PullsStateFilter[][]
local STATE_COMBINATIONS = {
	{ "open", "merged", "declined" },
	{ "open", "merged" },
	{ "open", "declined" },
	{ "merged", "declined" },
	{ "declined" },
	{ "merged" },
	{ "open" },
}

---@type { query: string, states: PullsStateFilter[] }[]
local STATE_BLOCKS = {}
for _, states in ipairs(STATE_COMBINATIONS) do
	table.insert(STATE_BLOCKS, { query = state_query(states), states = states })
end
vim.list_extend(STATE_BLOCKS, {
	{ query = "state:closed -is:merged", states = { "declined" } },
	{ query = "state:closed", states = { "merged", "declined" } },
	{ query = "state:open", states = { "open" } },
	{ query = "is:closed", states = { "merged", "declined" } },
})

---@param view AtlasPullsViewConfig
---@return string, PullsStateFilter[]|nil
local function search_parts(view)
	---@cast view AtlasGitHubViewConfig
	local query = vim.trim(view.search or "")
	local states
	local padded = " " .. query .. " "
	local lower = padded:lower()
	for _, block in ipairs(STATE_BLOCKS) do
		local first, last = lower:find(" " .. block.query:lower() .. " ", 1, true)
		if first then
			local before = vim.trim(padded:sub(1, first - 1))
			local after = vim.trim(padded:sub(last + 1))
			if after:upper():match("^AND%s") then
				after = vim.trim(after:sub(4))
			elseif before:upper():match("%sAND$") then
				before = vim.trim(before:sub(1, -4))
			end
			query = vim.trim(before .. " " .. after)
			states = block.states
			break
		end
	end
	if query == "" then
		query = "is:pr"
	elseif not query:find("is:pr", 1, true) then
		query = "is:pr " .. query
	end
	return query, states
end

---@param view AtlasPullsViewConfig
---@return string[]
function M.queries(view)
	local base, states = search_parts(view)
	states = view._states or states or { "open" }
	local queries = {}
	for _, state in ipairs(states) do
		table.insert(queries, base .. " " .. STATE_QUERIES[state])
	end
	return queries
end

---@param view AtlasPullsViewConfig
---@return string, PullsStateFilter[]
function M.query(view)
	local base, states = search_parts(view)
	states = view._states or states or { "open" }
	return base .. " " .. state_query(states), states
end

return M
