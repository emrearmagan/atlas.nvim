---@type IssuesProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")
local helper = require("atlas.issues.ui.presentation")
local utils = require("atlas.ui.shared.utils")

---@param issue Issue
---@param _details IssueDetails|nil
---@param _loading boolean
---@return IssuesDetailHeaderField[]
function M.header_fields(issue, _details, _loading)
	---@cast issue AzureIssue
	return {
		{ label = "Project", value = issue.project },
		{ label = "Status", value = issue.status, hl = helper.status_hl(issue.status_id) },
		{ label = "Assignee", value = issue.assignee and issue.assignee.display_name or "Unassigned" },
		{ label = "Author", value = issue.reporter and issue.reporter.display_name or "Unknown" },
		{ label = "Created", value = utils.relative_time_text(issue.created_at), hl = "AtlasTextMuted" },
		{ label = "Updated", value = utils.relative_time_text(issue.updated_at), hl = "AtlasTextMuted" },
	}
end

---@param issue Issue
---@param details IssueDetails|nil
---@param _loading boolean
---@return IssuesDetailChip[]
function M.chips(issue, details, _loading)
	local chips = {}
	if issue.story_points then
		table.insert(chips, { label = issue.story_points .. " pts", hl = "AtlasTextMuted" })
	end
	for _, label in ipairs(details and details.labels or {}) do
		table.insert(chips, { label = label.name, hl = "AtlasChipActive" })
	end
	return chips
end

---@return IssuesDetailTabDefinition[]
function M.tabs()
	local overview_icon, overview_hl = icons.general("overview")
	local conversation_icon, conversation_hl = icons.general("conversation")
	local activity_icon, activity_hl = icons.pulls("activity")
	return {
		{
			key = "overview",
			label = "Overview",
			icon = { icon = overview_icon, hl_group = overview_hl },
			mod = require("atlas.issues.ui.detail.tabs.overview"),
		},
		{
			key = "conversation",
			label = "Conversation",
			icon = { icon = conversation_icon, hl_group = conversation_hl },
			mod = require("atlas.issues.ui.detail.tabs.conversation"),
		},
		{
			key = "activity",
			label = "History",
			icon = { icon = activity_icon, hl_group = activity_hl },
			mod = require("atlas.issues.ui.detail.tabs.activity"),
		},
	}
end

return M
