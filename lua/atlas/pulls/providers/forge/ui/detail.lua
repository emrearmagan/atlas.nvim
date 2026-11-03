local M = {}

local highlights = require("atlas.ui.highlights")
local header = require("atlas.pulls.ui.components.header")

local MAX_HASH_LEN = 12

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param loading boolean
---@return PullsDetailHeaderField[]
function M.header_fields(_pr, details, loading)
	if details == nil then
		return loading and { header.loading_field("Assignees") } or {}
	end
	local logins = {}
	for _, assignee in ipairs(details.assignees or {}) do
		local login = tostring(assignee.username or assignee.name or "")
		if login ~= "" then
			table.insert(logins, login)
		end
	end
	return { header.assignee_field(logins) }
end

---@param pr PullRequest
---@param details PullRequestDetails|nil
---@param _loading boolean
---@return PullsDetailChip[]
function M.chips(pr, details, _loading)
	local chips = {}
	local hash = tostring(pr.source and pr.source.commit_hash or "")
	if hash ~= "" then
		table.insert(chips, { label = hash:sub(1, MAX_HASH_LEN), hl = "AtlasTabInactive" })
	end
	for _, label in ipairs((details and details.labels) or {}) do
		if tostring(label.name or "") ~= "" then
			table.insert(chips, { label = label.name, hl = highlights.chip(label.color or "") })
		end
	end
	return chips
end

---@return PullsDetailTab[]
function M.tabs()
	return require("atlas.pulls.ui.detail").default_tabs()
end

return M
