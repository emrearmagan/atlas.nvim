-- Bitbucket query language:
-- https://developer.atlassian.com/cloud/bitbucket/rest/#filter-and-sort-api-objects

local M = {}

---@class BitbucketRepoTarget
---@field workspace string
---@field repo string

---@class BitbucketProjectTarget
---@field workspace string
---@field project string

---@alias BitbucketPullTarget BitbucketRepoTarget|BitbucketProjectTarget

---@class BitbucketParsedSearch
---@field targets BitbucketPullTarget[]
---@field query string|nil
---@field states PullsStateFilter[]|nil

---@param states PullsStateFilter[]
---@return string
local function state_filter(states)
	local values = {}
	for _, state in ipairs(states) do
		table.insert(values, string.format('"%s"', state:upper()))
	end
	if #values == 1 then
		return "state = " .. values[1]
	end
	return "state IN (" .. table.concat(values, ", ") .. ")"
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
	table.insert(STATE_BLOCKS, { query = state_filter(states), states = states })
end

---@param input string|nil
---@return BitbucketParsedSearch|nil, string|nil
function M.parse(input)
	local input_value = vim.trim(input or "")
	local tokens, current = {}, {}
	local quoted = false
	for i = 1, #input_value do
		local char = input_value:sub(i, i)
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

	local targets, query_tokens, seen = {}, {}, {}
	for _, token in ipairs(tokens) do
		local kind, value = token:match("^([%a]+):(.*)$")
		if kind == "repo" or kind == "project" then
			local workspace, name = value:match("^([^/%s]+)/([^/%s]+)$")
			if workspace == nil or name == nil then
				local target_name = kind == "project" and "key" or "name"
				return nil, string.format("%s must use %s:workspace/%s", kind, kind, target_name)
			end
			if not seen[token] then
				seen[token] = true
				if kind == "repo" then
					table.insert(targets, { workspace = workspace, repo = name })
				else
					table.insert(targets, { workspace = workspace, project = name })
				end
			end
		else
			table.insert(query_tokens, token)
		end
	end

	if #targets == 0 then
		return nil, "Add repo:workspace/name or project:workspace/key"
	end

	local value = table.concat(query_tokens, " ")
	local states
	local padded = " " .. value .. " "
	local upper = padded:upper()
	for _, block in ipairs(STATE_BLOCKS) do
		local first, last = upper:find((" " .. block.query .. " "):upper(), 1, true)
		if first then
			local before = vim.trim(padded:sub(1, first - 1))
			local after = vim.trim(padded:sub(last + 1))
			if after:upper():match("^AND%s") then
				after = vim.trim(after:sub(4))
			elseif before:upper():match("%sAND$") then
				before = vim.trim(before:sub(1, -4))
			end
			value = vim.trim(before .. " " .. after)
			if value:match("^%b()$") then
				value = vim.trim(value:sub(2, -2))
			end
			states = block.states
			break
		end
	end

	return {
		targets = targets,
		query = value ~= "" and value or nil,
		states = states,
	}, nil
end

---@param parsed BitbucketParsedSearch
---@param states PullsStateFilter[]
---@return string
function M.filter(parsed, states)
	local value = state_filter(states)
	if parsed.query then
		value = string.format("(%s) AND %s", parsed.query, value)
	end
	return value
end

---@param view AtlasPullsViewConfig
---@return string, PullsStateFilter[]
function M.query(view)
	---@cast view AtlasBitbucketViewConfig
	local parsed = M.parse(view.search)
	local states = view._states or (parsed and parsed.states) or { "open" }
	if parsed == nil then
		return vim.trim(view.search or ""), states
	end

	local parts = {}
	for _, target in ipairs(parsed.targets) do
		if target.repo then
			table.insert(parts, string.format("repo:%s/%s", target.workspace, target.repo))
		else
			table.insert(parts, string.format("project:%s/%s", target.workspace, target.project))
		end
	end
	table.insert(parts, M.filter(parsed, states))
	return table.concat(parts, " "), states
end

---@param workspace string
---@param repo string
---@param value string|nil
---@return string
function M.for_repo(workspace, repo, value)
	local scope = string.format("repo:%s/%s", workspace, repo)
	value = vim.trim(value or "")
	return value == "" and scope or (scope .. " " .. value)
end

return M
