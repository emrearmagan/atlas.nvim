---@type IssuesProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.issues.ui.presentation")
local spinner = require("atlas.ui.components.spinner")

-- Header fields

---@param issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesDetailHeaderField[]
function M.header_fields(issue, details, loading)
	---@cast issue JiraIssue
	local user_icon = icons.general("user")
	local priority = tostring(issue.priority or "-")
	local priority_icon, priority_hl = icons.issues_priority(priority)
	local priority_text = priority_icon ~= "" and string.format("%s %s", priority_icon, priority) or priority
	local assignee_name = issue.assignee and issue.assignee.display_name or ""
	local reporter_name = issue.reporter and issue.reporter.display_name or ""

	if assignee_name == "" then
		assignee_name = "Unassigned"
	end
	if reporter_name == "" then
		reporter_name = "Unknown"
	end

	local fields = {
		{
			label = "Status",
			value = tostring(issue.status or "Unknown"),
			hl = helper.status_hl(issue.status_id),
		},
		{
			label = "Priority",
			value = priority_text,
			hl = priority_hl,
		},
		{ label = "Assignee", value = assignee_name, hl = helper.person_hl(assignee_name) },
		{
			label = "Reporter",
			value = string.format("%s %s", user_icon, reporter_name),
			hl = helper.person_hl(reporter_name),
		},
	}

	if loading then
		table.insert(fields, {
			label = "Fields",
			value = spinner.with_text("Loading..."),
			hl = "AtlasTextMuted",
		})
	elseif details then
		---@cast details JiraIssueDetails
		for _, field in ipairs(details.custom_fields) do
			if field.display == "table" then
				table.insert(fields, {
					label = field.name,
					value = field.formatted,
					hl = field.hl_group or "Normal",
				})
			end
		end
	end

	return fields
end

-- Chips

---@param issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesDetailChip[]
function M.chips(issue, details, loading)
	local chips = {}

	local parent_key = issue.parent and issue.parent.key or nil
	if parent_key then
		table.insert(chips, {
			label = string.format("%s %s", icons.pulls("branch"), parent_key),
			hl = "AtlasJiraChipParent",
		})
	end

	local sp = issue.story_points
	if sp ~= nil then
		table.insert(chips, {
			label = string.format("%s %s", icons.issues_provider("jira", "provider"), sp),
			hl = "AtlasJiraChipStoryPoints",
		})
	end

	local due = utils.format_date(issue.duedate)
	if due ~= "" then
		table.insert(chips, {
			label = string.format("%s %s", icons.general("created"), due),
			hl = "AtlasJiraChipDueDate",
		})
	end

	if loading then
		table.insert(chips, { label = spinner.with_text("Loading..."), hl = "AtlasTextMuted" })
	elseif details then
		---@cast details JiraIssueDetails
		for _, field in ipairs(details.custom_fields) do
			if field.display == "chip" then
				table.insert(chips, {
					label = field.formatted,
					hl = field.hl_group or "AtlasChipActive",
				})
			end
		end
	end

	return chips
end

-- Tabs

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
			mod = require("atlas.issues.providers.jira.ui.overview"),
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
