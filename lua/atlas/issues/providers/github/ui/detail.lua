---@type IssuesProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.highlights")
local helper = require("atlas.issues.ui.presentation")
local spinner = require("atlas.ui.components.spinner")

---@param body string|nil
---@return integer completed, integer total
local function task_progress(body)
	local completed = 0
	local total = 0
	for line in (tostring(body or "") .. "\n"):gmatch("(.-)\n") do
		local mark = line:match("^%s*[-*+]%s+%[([xX%s])%]")
		if mark ~= nil then
			total = total + 1
			if mark:lower() == "x" then
				completed = completed + 1
			end
		end
	end
	return completed, total
end

---@param assignees AtlasUser[]
---@return string, string|table[]
local function assignees_display(assignees)
	if #assignees == 0 then
		return "Unassigned", "AtlasTextMuted"
	end

	local parts = {}
	local spans = {}
	local cursor = 0
	for i, assignee in ipairs(assignees) do
		local username = assignee.username
		local token = "@" .. username
		table.insert(parts, token)
		table.insert(spans, {
			start_col = cursor,
			end_col = cursor + #token,
			hl_group = helper.person_hl(username),
		})
		cursor = cursor + #token

		if i < #assignees then
			local sep = ", "
			table.insert(parts, sep)
			table.insert(spans, {
				start_col = cursor,
				end_col = cursor + #sep,
				hl_group = "AtlasTextMuted",
			})
			cursor = cursor + #sep
		end
	end

	return table.concat(parts), spans
end

---@param milestone GitHubIssueMilestone|nil
---@return string
local function milestone_display(milestone)
	if milestone == nil then
		return ""
	end

	local title = milestone.title
	if title == "" then
		return ""
	end

	local percent = milestone.progress_percentage
	local open_count = milestone.open_issues
	local closed_count = milestone.closed_issues
	local total = open_count and closed_count and (open_count + closed_count) or nil

	if percent == nil and total and total > 0 then
		percent = (closed_count / total) * 100
	end

	if percent ~= nil and total and total > 0 then
		return string.format("%s %d%% (%d/%d)", title, math.floor(percent + 0.5), closed_count, total)
	end
	if percent ~= nil then
		return string.format("%s %d%%", title, math.floor(percent + 0.5))
	end
	if total and total > 0 then
		return string.format("%s %d/%d", title, closed_count, total)
	end
	return title
end

-- Header fields

---@param issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesDetailHeaderField[]
function M.header_fields(issue, details, _loading)
	---@cast issue GitHubIssue
	---@cast details GitHubIssueDetails|nil
	local reporter_name = issue.reporter and issue.reporter.name or ""
	if reporter_name == "" then
		reporter_name = "Unknown"
	end

	local assignees = details and details.assignees or (issue.assignee and { issue.assignee } or {})
	local assignees_text, assignees_hl = assignees_display(assignees)

	local fields = {
		{
			label = "Status",
			value = tostring(issue.status or "Open"),
			hl = issue.status_id == "closed" and "AtlasIssueClosedChip" or "AtlasIssueOpenChip",
		},
		{
			label = "Reporter",
			value = string.format("%s %s", icons.general("user"), reporter_name),
			hl = helper.person_hl(reporter_name),
		},
		{ label = "Assignee", value = assignees_text, hl = assignees_hl },
	}

	local parent = issue.parent
	if parent then
		local pkey = parent.key
		local title = tostring(parent.title or "")
		local text = title ~= "" and string.format("%s %s", pkey, title) or pkey
		local hl = helper.issue_hl(pkey)
		table.insert(fields, { label = "Parent", value = text, hl = hl })
	end

	local milestone_text = milestone_display(details and details.milestone or nil)
	if milestone_text ~= "" then
		table.insert(fields, { label = "Milestone", value = milestone_text, hl = "AtlasTextMuted" })
	end

	local subs = details and details.sub_issues or {}
	if #subs > 0 then
		local closed = 0
		for _, s in ipairs(subs) do
			if s.status_id == "closed" then
				closed = closed + 1
			end
		end
		table.insert(fields, {
			label = "Sub-issues",
			value = string.format("%s %d/%d", icons.issues("issue"), closed, #subs),
			hl = closed == #subs and "AtlasTextPositive" or "AtlasTextMuted",
		})
	end

	local completed, total = task_progress(details and details.description or nil)
	if total > 0 then
		table.insert(fields, {
			label = "Tasks",
			value = string.format("%s %d/%d", icons.pulls("tasks"), completed, total),
			hl = completed == total and "AtlasTextPositive" or "AtlasTextWarning",
		})
	end

	return fields
end

-- Chips: labels

---@param _issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesDetailChip[]
function M.chips(_issue, details, loading)
	---@cast details GitHubIssueDetails|nil
	local chips = {}
	if loading then
		table.insert(chips, { label = spinner.with_text("Loading..."), hl = "AtlasTextMuted" })
		return chips
	end

	for _, label in ipairs(details and details.labels or {}) do
		local name = label.name
		if name ~= "" then
			table.insert(chips, { label = name, hl = highlights.chip(label.color) })
		end
	end

	return chips
end

---@return IssuesDetailTabDefinition[]
function M.tabs()
	local overview_icon = icons.general("overview")
	local conversation_icon = icons.general("conversation")
	return {
		{
			key = "overview",
			label = "Overview",
			icon = { icon = overview_icon },
			mod = require("atlas.issues.ui.detail.tabs.overview"),
		},
		{
			key = "conversation",
			label = "Conversation",
			icon = { icon = conversation_icon },
			mod = require("atlas.issues.ui.detail.tabs.conversation"),
		},
	}
end

return M
