local M = {}

local notify = require("atlas.core.notify")
local prompt = require("atlas.commands.search.prompt")
local query = require("atlas.providers.bitbucket.query")

local FIELDS = {
	"id",
	"state",
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
local STATE_OPERATORS = { "=", "IN" }
local TEXT_OPERATORS = { "=", "!=", "~", "!~", "IN", "NOT" }
local COMPARISON_OPERATORS = { "=", "!=", ">", ">=", "<", "<=", "IN", "NOT" }
local LOGICAL_OPERATORS = { "AND", "OR" }
local SCOPE_QUALIFIERS = { "repo:", "project:" }
local VALUES = {
	draft = { "true", "false", "null" },
	state = { '"OPEN"', '"MERGED"', '"DECLINED"' },
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
	local left = cmdline:sub(1, cursorpos):gsub("^%s*:", "")
	local _, command_end = left:find("^[^%s]+%s*")
	local value = command_end and left:sub(command_end + 1) or ""
	local tokens, current = {}, {}
	local quoted = false
	for i = 1, #value do
		local char = value:sub(i, i)
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

	local partial = value:match("%s$") and "" or table.remove(tokens) or ""
	local opening = partial:match("^(%(*).*$") or ""
	local prefix = clean(partial)
	local query_tokens = {}
	local has_scope = false
	for _, token in ipairs(tokens) do
		local kind, scope = token:match("^([%a]+):(.*)$")
		if kind == "repo" or kind == "project" then
			if not scope:match("^([^/%s]+)/([^/%s]+)$") then
				return {}
			end
			has_scope = true
		else
			table.insert(query_tokens, token)
		end
	end
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
		local prior = clean(tokens[#tokens - 1] or ""):upper()
		if #tokens == 1 or prior == "AND" or prior == "OR" then
			return {}
		end
		return matches(FIELDS, prefix, opening)
	end

	if FIELD_SET[previous] then
		local operators = TEXT_OPERATORS
		if previous == "state" then
			operators = STATE_OPERATORS
		elseif EQUALITY_FIELDS[previous] then
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
---@param on_submit fun(query: string)
function M.edit(view, on_submit)
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
			local _, err = query.parse(value)
			if err then
				notify.warn(err)
				return
			end
			on_submit(value)
		end,
	})
end

---@param view AtlasBitbucketViewConfig
function M.open(view)
	M.edit(view, function(value)
		require("atlas").open("pulls", "bitbucket", {
			initial_view = {
				name = "Search",
				layout = "compact",
				search = value,
			},
		})
	end)
end

return M
