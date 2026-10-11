---@type PullsProviderDetail
local M = {}

local header = require("atlas.pulls.ui.components.header")
local highlights = require("atlas.ui.highlights")

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param loading boolean
---@return PullsDetailHeaderField[]
function M.header_fields(_pr, details, loading)
	if details == nil then
		return loading and { header.loading_field("Assignees") } or {}
	end
	---@cast details GitLabPullRequestDetails

	local logins = {}
	for _, assignee in ipairs(details.assignees) do
		local login = tostring(assignee.username or assignee.name or "")
		if login ~= "" then
			table.insert(logins, login)
		end
	end

	return { header.assignee_field(logins) }
end

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param loading boolean
---@return PullsDetailChip[]
function M.chips(_pr, details, loading)
	if details == nil or loading then
		return {}
	end

	local chips = {}
	local MAX_LABELS = 10
	---@cast details GitLabPullRequestDetails
	local labels = details.labels
	local shown = 0
	for _, label in ipairs(labels) do
		---@cast label GitLabPullsLabel
		local name = label.name
		if name ~= "" then
			if shown >= MAX_LABELS then
				break
			end
			local hl = highlights.chip(label.color, { fg = label.text_color })
			table.insert(chips, { label = name, hl = hl })
			shown = shown + 1
		end
	end
	local remaining = #labels - shown
	if remaining > 0 then
		table.insert(chips, { label = string.format("+%d more", remaining), hl = "AtlasTextMuted" })
	end
	return chips
end

---@return PullsDetailTab[]
function M.tabs()
	return require("atlas.pulls.ui.detail").default_tabs()
end

return M
