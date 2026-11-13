-- GitHub search syntax:
--   https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests
--   https://docs.github.com/en/search-github/getting-started-with-searching-on-github/understanding-the-search-syntax

local M = {}

local cli = require("atlas.providers.github.client")
local prompt = require("atlas.ui.prompt")
local utils = require("atlas.core.utils")

local DEFAULT_ISSUE_TYPES = { "Task", "Bug", "Feature" }

---@type string|nil
local local_slug = nil
---@type table<string, boolean>
local pending = {}

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

---@param slug string
---@return string
local function issue_types_key(slug)
	return "github_search:issue_types:" .. slug:lower()
end

---@param slug string
local function prefetch_issue_types(slug)
	local key = issue_types_key(slug)
	local _, ok = cli.get_mem(key)
	if ok or pending[key] then
		return
	end
	pending[key] = true
	require("atlas.issues.providers.github.api.issues").list_issue_types(slug, function(types)
		pending[key] = nil
		if types then
			cli.set_mem(
				key,
				vim.tbl_map(function(item)
					return item.name
				end, types)
			)
		end
	end)
end

---@param query string
---@return string[]
local function type_values(query)
	local slug = local_slug
	for repo in query:gmatch("repo:([%w%-%._]+/[%w%-%._]+)") do
		slug = repo
	end

	local names = DEFAULT_ISSUE_TYPES
	if slug then
		local cached, ok = cli.get_mem(issue_types_key(slug))
		if ok then
			names = cached
		else
			prefetch_issue_types(slug)
		end
	end

	return vim.tbl_map(function(name)
		return name:find("%s") and ('"' .. name .. '"') or name
	end, names)
end

---@param _arglead string
---@param cmdline string
---@param cursorpos integer
---@return string[]
local function complete_cmdline(_arglead, cmdline, cursorpos)
	local left = cmdline:sub(1, cursorpos):gsub("^%s*:", "")
	local _, command_end = left:find("^[^%s]+%s*")
	local query = command_end and left:sub(command_end + 1) or ""
	local tokens = utils.split_tokens(query)

	local partial = ""
	if not query:match("%s$") and #tokens > 0 then
		partial = tokens[#tokens]
	end

	if partial:find(":") then
		local qualifier, value_prefix = partial:match("^([%w%-]+):(.*)$")
		if qualifier ~= nil then
			local values = qualifier:lower() == "type" and type_values(query) or VALUES[qualifier:lower()]
			return matches(values or {}, lower_trim(value_prefix), qualifier)
		end
	end

	return matches(QUALIFIERS, lower_trim(partial), nil)
end

---@param default string
---@param on_submit fun(query: string)
function M.edit(default, on_submit)
	require("atlas.core.git").local_repository(nil, function(info)
		local_slug = info and info.provider == "github" and info.repo_full_name or nil
		if local_slug then
			prefetch_issue_types(local_slug)
		end
	end)
	type_values(default or "")
	prompt.open({
		name = "AtlasGitHubSearch",
		prompt = "GitHub search: ",
		complete = complete_cmdline,
		on_submit = function(query)
			query = vim.trim(tostring(query or ""))
			if query == "" then
				return
			end
			on_submit(query)
		end,
		default = default,
	})
end

---@param default? string
function M.open(default)
	M.edit(default or "is:pr ", function(query)
		local kind = query:find("is:issue") and "issues" or "pulls"
		require("atlas").open(kind, "github", {
			initial_view = { name = "Search", layout = "compact", search = query },
		})
	end)
end

return M
