---@type IssuesProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")
local helper = require("atlas.issues.ui.presentation")
local utils = require("atlas.ui.shared.utils")

---@param issue ShortcutIssue
---@param details IssueDetails|nil
---@return string
local function owners_text(issue, details)
	if details then
		local names = {}
		for _, owner in ipairs(details.assignees) do
			table.insert(names, owner.display_name)
		end
		return #names > 0 and table.concat(names, ", ") or "Unassigned"
	end

	if issue.assignee == nil then
		return "Unassigned"
	end
	if issue.owner_count > 1 then
		return string.format("%s +%d", issue.assignee.display_name, issue.owner_count - 1)
	end
	return issue.assignee.display_name
end

---@param issue Issue
---@param details IssueDetails|nil
---@param _loading boolean
---@return IssuesDetailHeaderField[]
function M.header_fields(issue, details, _loading)
	---@cast issue ShortcutIssue
	local owners = owners_text(issue, details)
	local requester = issue.reporter and issue.reporter.display_name or "Unknown"
	local fields = {
		{ label = "Status", value = issue.status or "Unknown", hl = helper.status_hl(issue.status_id) },
		{ label = "Owners", value = owners, hl = helper.person_hl(issue.assignee and issue.assignee.display_name) },
		{ label = "Requester", value = requester, hl = helper.person_hl(requester) },
	}

	if issue.created_at then
		table.insert(fields, {
			label = "Created",
			value = utils.relative_time_text(issue.created_at),
			hl = "AtlasTextMuted",
		})
	end
	if issue.updated_at then
		table.insert(fields, {
			label = "Updated",
			value = utils.relative_time_text(issue.updated_at),
			hl = "AtlasTextMuted",
		})
	end

	return fields
end

---@param issue Issue
---@param details IssueDetails|nil
---@param _loading boolean
---@return IssuesDetailChip[]
function M.chips(issue, details, _loading)
	---@cast issue ShortcutIssue
	---@cast details ShortcutIssueDetails|nil
	local chips = {}

	if issue.story_points ~= nil then
		table.insert(chips, { label = string.format("%s pts", issue.story_points), hl = "AtlasTextMuted" })
	end

	local deadline = utils.format_date(issue.duedate)
	if deadline ~= "" then
		table.insert(chips, {
			label = string.format("%s %s", icons.general("created"), deadline),
			hl = "AtlasTextMuted",
		})
	end

	local labels = details and details.labels or issue.labels
	for _, label in ipairs(labels) do
		table.insert(chips, {
			label = string.format("%s %s", icons.general("tag"), label.name),
			hl = "AtlasChipActive",
		})
	end

	if details and details.parent then
		table.insert(chips, {
			label = string.format("%s #%s", icons.pulls("branch"), details.parent.key),
			hl = "AtlasShortcutChipParent",
		})
	end

	return chips
end

---@return IssuesDetailTabDefinition[]
function M.tabs()
	local overview_icon, overview_hl = icons.general("overview")
	local conversation_icon, conversation_hl = icons.general("conversation")
	return {
		{
			key = "overview",
			label = "Overview",
			icon = { icon = overview_icon, hl_group = overview_hl },
			mod = require("atlas.issues.providers.shortcut.ui.overview"),
		},
		{
			key = "conversation",
			label = "Conversation",
			icon = { icon = conversation_icon, hl_group = conversation_hl },
			mod = require("atlas.issues.ui.detail.tabs.conversation"),
		},
	}
end

return M
