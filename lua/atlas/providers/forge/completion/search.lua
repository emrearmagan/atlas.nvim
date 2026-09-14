local M = {}
local prompt = require("atlas.commands.search.prompt")

local QUALIFIERS = {
	pulls = { "repo:", "is:", "type:", "search:", "param." },
	issues = { "repo:", "is:", "type:", "search:", "param.", "state:", "scope:", "labels:", "label:" },
}
local PULL_STATES = { "open", "merged", "declined", "closed", "all" }
local ISSUE_STATES = { "open", "closed", "all" }
local VALUES = {
	pulls = { is = PULL_STATES, type = { "pulls" } },
	issues = {
		is = ISSUE_STATES,
		state = ISSUE_STATES,
		scope = { "assigned", "created", "mentioned", "all" },
		type = { "issues" },
	},
}

---@param cmdline string
---@param cursorpos integer
---@return string|nil
local function current_token(cmdline, cursorpos)
	local left = cmdline:sub(1, cursorpos):gsub("^%s*:", "")
	local query = left:match("^%s*%S+%s+(.*)$") or ""
	local start, quoted, escaped = 1, false, false
	for index = 1, #query do
		local char = query:sub(index, index)
		if escaped then
			escaped = false
		elseif char == "\\" and quoted then
			escaped = true
		elseif char == '"' then
			quoted = not quoted
		elseif char:match("%s") and not quoted then
			start = index + 1
		end
	end
	return not quoted and query:sub(start) or nil
end

---@param domain "pulls"|"issues"
---@param cmdline string
---@param cursorpos integer
---@return string[]
local function complete(domain, cmdline, cursorpos)
	local token = current_token(cmdline, cursorpos)
	if token == nil then
		return {}
	end
	local key, value = token:match("^([%w_%-]+):(.*)$")
	local choices, prefix, opening = QUALIFIERS[domain], token, ""
	if key then
		choices = VALUES[domain][key:lower()] or {}
		prefix, opening = value, key .. ":"
		if domain == "pulls" and key:lower() == "is" then
			local previous, last = value:match("^(.*,)([^,]*)$")
			if previous then
				prefix, opening = last, opening .. previous
			end
		end
	end
	local matches = {}
	for _, choice in ipairs(choices) do
		if choice:sub(1, #prefix):lower() == prefix:lower() then
			table.insert(matches, opening .. choice)
		end
	end
	table.sort(matches)
	return matches
end

---@param provider_id "gitea"|"forgejo"
---@param domain "pulls"|"issues"
---@param default string|nil
---@param on_submit fun(query: string)
function M.edit(provider_id, domain, default, on_submit)
	local provider_name = provider_id == "gitea" and "Gitea" or "Forgejo"
	prompt.open({
		name = "Atlas" .. provider_name .. (domain == "pulls" and "PullSearch" or "IssueSearch"),
		default = default,
		complete = function(_, cmdline, cursorpos)
			return complete(domain, cmdline, cursorpos)
		end,
		on_submit = function(value)
			value = vim.trim(tostring(value or ""))
			if value ~= "" then
				on_submit(value)
			end
		end,
	})
end

return M
