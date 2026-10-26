---@type PullsProviderDetail
local M = {}

local header = require("atlas.pulls.ui.components.header")
local highlights = require("atlas.ui.highlights")
local stack = require("atlas.pulls.stack")

-- Detail

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param loading boolean
---@return PullsDetailHeaderField[]
function M.header_fields(_pr, details, loading)
	---@cast details GitHubPullRequestDetails|nil
	if details == nil then
		return loading and { header.loading_field("Assignees") } or {}
	end

	local logins = vim.tbl_map(function(assignee)
		return assignee.username
	end, details.assignees)

	return { header.assignee_field(logins) }
end

---@param pr PullRequest
---@param details PullRequestDetails|nil
---@param _loading boolean
---@return PullsDetailChip[]
function M.chips(pr, details, _loading)
	---@cast details GitHubPullRequestDetails|nil
	local chips = {}

	local indicator = stack.indicator(pr.stack)
	if indicator then
		table.insert(chips, { label = indicator, hl = "AtlasRelatedChip" })
	end

	for _, lbl in ipairs(details and details.labels or {}) do
		table.insert(chips, { label = lbl.name, hl = highlights.label(lbl.color) })
	end

	return chips
end

-- Tabs

---@return PullsDetailTab[]
function M.tabs()
	return require("atlas.pulls.ui.detail").default_tabs()
end

return M
