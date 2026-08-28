-- Bitbucket query language:
-- https://developer.atlassian.com/cloud/bitbucket/rest/#filter-and-sort-api-objects

local M = {}

local notify = require("atlas.core.notify")
local prompt = require("atlas.commands.search.prompt")

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

local FIELDS = {
	"id",
	"title",
	"description",
	"draft",
	"author.nickname",
	"author.uuid",
	"reviewers.nickname",
	"reviewers.uuid",
	"source.branch.name",
	"source.repository.full_name",
	"destination.branch.name",
	"destination.repository.full_name",
	"created_on",
	"updated_on",
	"comment_count",
	"task_count",
}

local EQUALITY_OPERATORS = { "=", "!=" }
local TEXT_OPERATORS = { "=", "!=", "~", "!~", "IN", "NOT" }
local COMPARISON_OPERATORS = { "=", "!=", ">", ">=", "<", "<=", "IN", "NOT" }
local LOGICAL_OPERATORS = { "AND", "OR" }
local SCOPE_QUALIFIERS = { "repo:", "project:" }
local SCOPE_KINDS = { repo = true, project = true }

local VALUES = {
	draft = { "true", "false", "null" },
}

local FIELD_SET = {}
for _, field in ipairs(FIELDS) do
	FIELD_SET[field] = true
end

local EQUALITY_FIELDS = {
	draft = true,
	["author.nickname"] = true,
	["reviewers.nickname"] = true,
	["source.repository.full_name"] = true,
	["destination.repository.full_name"] = true,
}
local COMPARABLE_FIELDS = { id = true, created_on = true, updated_on = true, comment_count = true, task_count = true }

local OPERATOR_SET = {}
for _, operators in ipairs({ TEXT_OPERATORS, COMPARISON_OPERATORS }) do
	for _, operator in ipairs(operators) do
		OPERATOR_SET[operator] = true
	end
end

local ROOT_ITEMS = {}
vim.list_extend(ROOT_ITEMS, SCOPE_QUALIFIERS)
vim.list_extend(ROOT_ITEMS, FIELDS)

local QUERY_TAIL_ITEMS = {}
vim.list_extend(QUERY_TAIL_ITEMS, LOGICAL_OPERATORS)
vim.list_extend(QUERY_TAIL_ITEMS, SCOPE_QUALIFIERS)

---@param query string
---@return string[], boolean
local function tokenize(query)
	local tokens, current = {}, {}
	local quoted = false
	for i = 1, #query do
		local char = query:sub(i, i)
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
	return tokens, query:match("%s$") ~= nil
end

---@param token string
---@return BitbucketPullTarget|nil, string|nil
local function scope_from_token(token)
	local kind, value = token:match("^([%a]+):(.*)$")
	if not SCOPE_KINDS[kind] then
		return nil, nil
	end

	local workspace, name = value:match("^([^/%s]+)/([^/%s]+)$")
	if workspace == nil or name == nil then
		local target_name = kind == "project" and "key" or "name"
		return nil, string.format("%s must use %s:workspace/%s", kind, kind, target_name)
	end

	if kind == "repo" then
		return { workspace = workspace, repo = name }, nil
	end
	return { workspace = workspace, project = name }, nil
end

---@param tokens string[]
---@return BitbucketPullTarget[], string[], string|nil
local function split_scopes(tokens)
	local targets, query_tokens, seen = {}, {}, {}
	for _, token in ipairs(tokens) do
		local target, err = scope_from_token(token)
		if err then
			return {}, {}, err
		end
		if target then
			if not seen[token] then
				seen[token] = true
				table.insert(targets, target)
			end
		else
			table.insert(query_tokens, token)
		end
	end
	return targets, query_tokens, nil
end

---@param token string
---@return boolean
local function is_logical_operator(token)
	local upper = token:upper()
	return upper == "AND" or upper == "OR"
end

---@param input string|nil
---@return BitbucketParsedSearch|nil, string|nil
function M.parse(input)
	local tokens = tokenize(vim.trim(input or ""))
	local targets, query_tokens, err = split_scopes(tokens)
	if err then
		return nil, err
	end

	if #targets == 0 then
		return nil, "Add repo:workspace/name or project:workspace/key"
	end

	local query = table.concat(query_tokens, " ")
	local parsed = {
		targets = targets,
		query = query ~= "" and query or nil,
	}
	return parsed, nil
end

---@param workspace string
---@param repo string
---@param query string|nil
---@return string
function M.for_repo(workspace, repo, query)
	local scope = string.format("repo:%s/%s", workspace, repo)
	query = vim.trim(query or "")
	return query == "" and scope or (scope .. " " .. query)
end

---@param cmdline string
---@param cursorpos integer
---@return string
local function extract_query(cmdline, cursorpos)
	local left = cmdline:sub(1, cursorpos):gsub("^%s*:", "")
	local _, command_end = left:find("^[^%s]+%s*")
	return command_end and left:sub(command_end + 1) or ""
end

---@param token string
---@return string
local function clean(token)
	return (token:gsub("^[%(]+", ""):gsub("[%),]+$", ""))
end

---@param items string[]
---@param prefix string
---@param opening string
---@return string[]
local function matches(items, prefix, opening)
	local result = {}
	local needle = prefix:lower()
	for _, item in ipairs(items) do
		if item:lower():sub(1, #needle) == needle then
			table.insert(result, opening .. item)
		end
	end
	return result
end

---@param _arglead string
---@param cmdline string
---@param cursorpos integer
---@return string[]
local function complete_cmdline(_arglead, cmdline, cursorpos)
	local query = extract_query(cmdline, cursorpos)
	local tokens, trailing_space = tokenize(query)
	local partial = trailing_space and "" or table.remove(tokens) or ""
	local opening = partial:match("^(%(*).*$") or ""
	local prefix = clean(partial)
	local targets, query_tokens, err = split_scopes(tokens)
	if err then
		return {}
	end
	local has_scope = #targets > 0
	tokens = query_tokens
	if #tokens == 0 then
		if partial:match("^[%a]+:") then
			return {}
		end
		if opening ~= "" and has_scope then
			return matches(FIELDS, prefix, opening)
		end
		return matches(has_scope and ROOT_ITEMS or SCOPE_QUALIFIERS, prefix, opening)
	end
	local previous = clean(tokens[#tokens])
	local previous_upper = previous:upper()

	if previous == "" or previous_upper == "AND" or previous_upper == "OR" then
		if #tokens == 1 or is_logical_operator(tokens[#tokens - 1]) then
			return {}
		end
		return matches(FIELDS, prefix, opening)
	end

	if FIELD_SET[previous] then
		local operators = TEXT_OPERATORS
		if EQUALITY_FIELDS[previous] then
			operators = EQUALITY_OPERATORS
		elseif COMPARABLE_FIELDS[previous] then
			operators = COMPARISON_OPERATORS
		end
		return matches(operators, prefix:upper(), opening)
	end

	if previous_upper == "NOT" then
		return matches({ "IN" }, prefix:upper(), opening)
	end

	if OPERATOR_SET[previous_upper] then
		if previous_upper ~= "=" and previous_upper ~= "!=" then
			return {}
		end
		local field_token = tokens[#tokens - 1]
		if field_token == nil then
			return {}
		end
		local field = clean(field_token)
		return matches(VALUES[field] or {}, prefix, opening)
	end

	return matches(QUERY_TAIL_ITEMS, prefix:upper(), opening)
end

---@param view AtlasBitbucketViewConfig
function M.open(view)
	local default = vim.trim(view.search or "")
	if default ~= "" then
		default = default .. " "
	end

	prompt.open({
		name = "AtlasBitbucketSearch",
		complete = complete_cmdline,
		default = default,
		on_submit = function(value)
			value = vim.trim(value)
			if value == "" then
				return
			end
			local _, err = M.parse(value)
			if err then
				notify.warn(err)
				return
			end
			require("atlas").open("pulls", "bitbucket", {
				initial_view = {
					name = "Search",
					layout = "compact",
					search = value,
				},
			})
		end,
	})
end

return M
