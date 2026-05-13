-- Docs:
--   https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests
--   https://docs.github.com/en/search-github/getting-started-with-searching-on-github/understanding-the-search-syntax

local M = {}

---@type string[]
local QUALIFIERS = {
	"is",
	"type",
	"state",
	"in",
	"user",
	"org",
	"repo",
	"author",
	"assignee",
	"mentions",
	"commenter",
	"involves",
	"team",
	"team-review-requested",
	"review",
	"review-requested",
	"reviewed-by",
	"label",
	"milestone",
	"project",
	"no",
	"linked",
	"head",
	"base",
	"status",
	"draft",
	"merged",
	"archived",
	"language",
	"comments",
	"interactions",
	"reactions",
	"created",
	"updated",
	"closed",
	"sort",
}

---@type table<string, string[]>
local VALUES = {
	["is"] = { "pr", "issue", "open", "closed", "merged", "queued", "draft", "locked", "public", "private", "archived" },
	["type"] = { "pr", "issue" },
	["state"] = { "open", "closed" },
	["in"] = { "title", "body", "comments" },
	["no"] = { "label", "milestone", "assignee", "project" },
	["linked"] = { "pr", "issue" },
	["review"] = { "none", "required", "approved", "changes_requested" },
	["draft"] = { "true", "false" },
	["archived"] = { "true", "false" },
	["status"] = { "pending", "success", "failure" },
	["sort"] = {
		"created-asc",
		"created-desc",
		"updated-asc",
		"updated-desc",
		"comments-asc",
		"comments-desc",
		"reactions-asc",
		"reactions-desc",
		"interactions-asc",
		"interactions-desc",
	},
}

---@param value string
---@return string
local function lower_trim(value)
	return vim.trim(tostring(value or "")):lower()
end

---@param cmdline string
---@param cursorpos integer
---@return string
local function extract_query(cmdline, cursorpos)
	local raw = tostring(cmdline or "")
	local pos = math.max(0, math.min(tonumber(cursorpos) or #raw, #raw))
	local left = raw:sub(1, pos)
	left = left:gsub("^%s*:", "")

	local _, cmd_end = left:find("^[^%s]+%s*")
	if not cmd_end then
		return ""
	end

	return left:sub(cmd_end + 1)
end

---@param value string
---@param token string
---@return boolean
local function token_match(value, token)
	if token == "" then
		return true
	end
	local v = lower_trim(value)
	if #token <= 3 then
		return v:sub(1, #token) == token
	end
	return v:find(token, 1, true) ~= nil
end

---@param query string
---@return string[], boolean
local function tokenize_query(query)
	local text = tostring(query or "")
	local tokens = {}
	local buf = {}
	local in_quotes = false

	for i = 1, #text do
		local ch = text:sub(i, i)
		if ch == '"' then
			in_quotes = not in_quotes
			table.insert(buf, ch)
		elseif ch:match("%s") and not in_quotes then
			if #buf > 0 then
				table.insert(tokens, table.concat(buf))
				buf = {}
			end
		else
			table.insert(buf, ch)
		end
	end

	if #buf > 0 then
		table.insert(tokens, table.concat(buf))
	end

	return tokens, text:match("%s$") ~= nil
end

---@param prefix string
---@return string[]
local function complete_qualifier(prefix)
	local results = {}
	for _, q in ipairs(QUALIFIERS) do
		if token_match(q, prefix) then
			table.insert(results, q .. ":")
		end
	end
	table.sort(results)
	return results
end

---@param qualifier string
---@param prefix string
---@return string[]
local function complete_value(qualifier, prefix)
	local values = VALUES[qualifier:lower()]
	if values == nil then
		return {}
	end

	local results = {}
	for _, v in ipairs(values) do
		if token_match(v, prefix) then
			table.insert(results, string.format("%s:%s", qualifier, v))
		end
	end
	table.sort(results)
	return results
end

---@param token string
---@return string|nil qualifier, string|nil value_prefix
local function split_token(token)
	local q, v = token:match("^([%w%-]+):(.*)$")
	if q == nil then
		return nil, nil
	end
	return q, v or ""
end

---@param _arglead string
---@param cmdline string
---@param cursorpos integer
---@return string[]
function M.complete_cmdline(_arglead, cmdline, cursorpos)
	local query = extract_query(cmdline, cursorpos)
	local tokens, trailing_space = tokenize_query(query)

	local partial = ""
	if not trailing_space and #tokens > 0 then
		partial = tokens[#tokens]
	end

	if partial:find(":") then
		local qualifier, value_prefix = split_token(partial)
		if qualifier ~= nil then
			return complete_value(qualifier, lower_trim(value_prefix or ""))
		end
	end

	return complete_qualifier(lower_trim(partial))
end

return M
