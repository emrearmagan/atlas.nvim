-- GitHub search syntax:
--   https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests
--   https://docs.github.com/en/search-github/getting-started-with-searching-on-github/understanding-the-search-syntax

local M = {}

local prompt = require("atlas.commands.search.prompt")

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

---@param items string[]
---@param prefix string
---@param qualifier string|nil
---@return string[]
local function matches(items, prefix, qualifier)
	local results = {}
	for _, item in ipairs(items) do
		local value = lower_trim(item)
		local matched = prefix == ""
			or (#prefix <= 3 and value:sub(1, #prefix) == prefix)
			or (#prefix > 3 and value:find(prefix, 1, true) ~= nil)
		if matched then
			table.insert(results, qualifier and (qualifier .. ":" .. item) or (item .. ":"))
		end
	end
	table.sort(results)
	return results
end

---@param _arglead string
---@param cmdline string
---@param cursorpos integer
---@return string[]
local function complete_cmdline(_arglead, cmdline, cursorpos)
	local left = cmdline:sub(1, cursorpos):gsub("^%s*:", "")
	local _, command_end = left:find("^[^%s]+%s*")
	local query = command_end and left:sub(command_end + 1) or ""
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

	local partial = ""
	if not query:match("%s$") and #tokens > 0 then
		partial = tokens[#tokens]
	end

	if partial:find(":") then
		local qualifier, value_prefix = partial:match("^([%w%-]+):(.*)$")
		if qualifier ~= nil then
			return matches(VALUES[qualifier:lower()] or {}, lower_trim(value_prefix), qualifier)
		end
	end

	return matches(QUALIFIERS, lower_trim(partial), nil)
end

---@param default? string
function M.open(default)
	prompt.open({
		name = "AtlasGitHubSearch",
		complete = complete_cmdline,
		on_submit = function(query)
			query = vim.trim(tostring(query or ""))
			if query == "" then
				return
			end
			local kind = query:find("is:issue") and "issues" or "pulls"
			require("atlas").open(kind, "github", {
				initial_view = { name = "Search", layout = "compact", search = query },
			})
		end,
		default = default or "is:pr ",
	})
end

return M
