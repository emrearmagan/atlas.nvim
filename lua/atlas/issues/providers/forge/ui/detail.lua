local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.issues.ui.presentation")
local spinner = require("atlas.ui.components.spinner")
local highlights = require("atlas.ui.highlights")

---@param assignees AtlasUser[]
---@return string, string|table[]
local function assignees_display(assignees)
	local parts, spans = {}, {}
	local cursor = 0
	for _, assignee in ipairs(assignees) do
		local login = tostring(assignee.username or assignee.name or "")
		if login ~= "" then
			if #parts > 0 then
				table.insert(parts, ", ")
				cursor = cursor + 2
			end
			local value = "@" .. login
			table.insert(parts, value)
			table.insert(spans, {
				start_col = cursor,
				end_col = cursor + #value,
				hl_group = helper.person_hl(login),
			})
			cursor = cursor + #value
		end
	end
	if #parts == 0 then
		return "Unassigned", "AtlasTextMuted"
	end
	return table.concat(parts), spans
end

---@return IssuesDetailTabDefinition[]
local function tabs()
	local overview_icon, overview_hl = icons.get("overview")
	local conversation_icon, conversation_hl = icons.get("conversation")
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
	}
end

---@param issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesDetailHeaderField[]
function M.header_fields(issue, details, loading)
	local reporter = issue.reporter and tostring(issue.reporter.name or "") or ""
	if reporter == "" then
		reporter = "Unknown"
	end

	local assignees = details and details.assignees or (issue.assignee and { issue.assignee } or {})
	local assignee_text, assignee_hl = assignees_display(assignees)
	if loading and details == nil then
		assignee_text = spinner.with_text("Loading...")
		assignee_hl = "AtlasTextMuted"
	end

	local fields = {
		{
			label = "Status",
			value = tostring(issue.status or "Open"),
			hl = issue.status_id == "closed" and "AtlasIssueClosedChip" or "AtlasIssueOpenChip",
		},
		{
			label = "Author",
			value = string.format("%s %s", icons.get("user"), reporter),
			hl = helper.person_hl(reporter),
		},
		{ label = "Assignees", value = assignee_text, hl = assignee_hl },
	}

	local milestone = details and details.milestone
	if milestone and tostring(milestone.title or "") ~= "" then
		table.insert(fields, { label = "Milestone", value = milestone.title, hl = "AtlasTextMuted" })
	end
	if tostring(issue.created_at or "") ~= "" then
		table.insert(fields, {
			label = "Opened",
			value = utils.relative_time_text(issue.created_at) or issue.created_at,
			hl = "AtlasTextMuted",
		})
	end
	if issue.duedate then
		table.insert(fields, { label = "Due", value = issue.duedate, hl = "AtlasTextWarning" })
	end
	return fields
end

---@param _issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesDetailChip[]
function M.chips(_issue, details, loading)
	if loading then
		return { { label = spinner.with_text("Loading..."), hl = "AtlasTextMuted" } }
	end
	local chips = {}
	for _, label in ipairs(details and details.labels or {}) do
		if tostring(label.name or "") ~= "" then
			table.insert(chips, { label = label.name, hl = highlights.chip(label.color) })
		end
	end
	return chips
end

M.tabs = tabs

return M
