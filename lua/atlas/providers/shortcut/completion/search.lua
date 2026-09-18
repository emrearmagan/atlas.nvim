-- Shortcut search syntax: https://www.shortcut.com/help/fields-and-features/search-operators/
local M = {}

local prompt = require("atlas.commands.search.prompt")

local OPERATORS = {
	"owner",
	"requester",
	"type",
	"state",
	"is",
	"label",
	"team",
	"epic",
	"objective",
	"id",
	"title",
	"description",
	"comment",
	"has",
	"estimate",
	"created",
	"updated",
	"completed",
	"moved",
	"due",
	"pr",
	"branch",
	"commit",
	"skill-set",
	"product-area",
	"technical-area",
	"priority",
	"severity",
}

local VALUES = {
	["type"] = { "feature", "bug", "chore" },
	["is"] = { "story", "unstarted", "started", "done", "blocked", "blocker", "overdue", "archived", "unestimated" },
	["has"] = { "owner", "epic", "comment", "task", "label", "deadline", "attachment", "pr", "branch", "commit" },
	["created"] = { "today", "yesterday" },
	["updated"] = { "today", "yesterday" },
	["completed"] = { "today", "yesterday" },
	["moved"] = { "today", "yesterday" },
	["due"] = { "today", "yesterday", "tomorrow" },
}

---@param items string[]
---@param prefix string
---@param before string
---@param after string
---@return string[]
local function matches(items, prefix, before, after)
	local results = {}
	prefix = prefix:lower()
	for _, item in ipairs(items) do
		if item:sub(1, #prefix) == prefix then
			table.insert(results, before .. item .. after)
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
	local token_start, quoted, escaped = 1, false, false
	for i = 1, #query do
		local char = query:sub(i, i)
		if escaped then
			escaped = false
		elseif char == "\\" then
			escaped = true
		elseif char == '"' then
			quoted = not quoted
		elseif char:match("%s") and not quoted then
			token_start = i + 1
		end
	end

	local partial = query:sub(token_start)
	if quoted or partial:find('"', 1, true) then
		return {}
	end

	local negation, operator, value = partial:match("^([!%-]?)([%w%-]+):(.*)$")
	if operator then
		return matches(VALUES[operator:lower()] or {}, value, negation .. operator .. ":", "")
	end

	local prefix
	negation, prefix = partial:match("^([!%-]?)([%w%-]*)$")
	if prefix then
		return matches(OPERATORS, prefix, negation, ":")
	end
	return {}
end

---@param default string|nil
---@param on_submit fun(query: string)
function M.edit(default, on_submit)
	prompt.open({
		name = "AtlasShortcutSearch",
		complete = complete_cmdline,
		on_submit = function(query)
			query = vim.trim(tostring(query or ""))
			if query ~= "" then
				on_submit(query)
			end
		end,
		default = default,
	})
end

return M
