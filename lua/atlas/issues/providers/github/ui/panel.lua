---@class GitHubIssuesProviderPanel : IssuesProviderPanel
local M = {}

local icons = require("atlas.ui.shared.icons")
local helper = require("atlas.issues.ui.main.helper")
local conversation_state = require("atlas.issues.providers.github.ui.conversation.state")
local activity_state = require("atlas.issues.providers.github.ui.activity.state")

---@param raw table
---@return table[]
local function assignee_nodes(raw)
	local assignees = type(raw.assignees) == "table" and raw.assignees or {}
	if type(assignees.nodes) == "table" then
		return assignees.nodes
	end
	return assignees
end

---@param raw table
---@return string, string|table[]
local function assignees_display(raw)
	local logins = {}
	for _, node in ipairs(assignee_nodes(raw)) do
		local login = type(node) == "table" and tostring(node.login or node.account_id or "") or ""
		if login ~= "" then
			table.insert(logins, login)
		end
	end

	if #logins == 0 then
		return "Unassigned", "AtlasTextMuted"
	end

	local parts = {}
	local spans = {}
	local cursor = 0
	for i, login in ipairs(logins) do
		local token = "@" .. login
		table.insert(parts, token)
		table.insert(spans, {
			start_col = cursor,
			end_col = cursor + #token,
			hl_group = helper.person_hl(login),
		})
		cursor = cursor + #token

		if i < #logins then
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

---@param value any
---@return number|nil
local function connection_count(value)
	if type(value) == "number" then
		return value
	end
	if type(value) == "table" then
		return tonumber(value.totalCount)
	end
	return nil
end

---@param milestone table|nil
---@return string
local function milestone_display(milestone)
	if type(milestone) ~= "table" then
		return ""
	end

	local title = tostring(milestone.title or "")
	if title == "" then
		return ""
	end

	local percent = tonumber(milestone.progressPercentage)
	local open_count = connection_count(milestone.openIssues) or tonumber(milestone.open_issues)
	local closed_count = connection_count(milestone.closedIssues) or tonumber(milestone.closed_issues)
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

--------------------------------------------------------------------------------
-- Header rows
--------------------------------------------------------------------------------

---@param issue Issue
---@return IssuesPanelHeaderRow[]
function M.header_rows(issue)
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local milestone_text = milestone_display(raw.milestone)
	local reporter_name = type(issue.reporter) == "table" and tostring(issue.reporter.display_name or "") or ""
	local assignees_text, assignees_hl = assignees_display(raw)
	local user_icon = icons.general("user")

	if reporter_name == "" then
		reporter_name = "Unknown"
	end

	local rows = {
		{
			k1 = "Status:",
			v1 = tostring(issue.status or "Open"),
			v1_hl = issue.status_id == "closed" and "AtlasGHIssueClosedChip" or "AtlasGHIssueOpenChip",
			k2 = "Reporter:",
			v2 = string.format("%s %s", user_icon, reporter_name),
			v2_hl = helper.person_hl(reporter_name),
		},
		{
			k1 = "Assignee:",
			v1 = assignees_text,
			v1_hl = assignees_hl,
			k2 = milestone_text ~= "" and "Milestone:" or "",
			v2 = milestone_text,
			v2_hl = milestone_text ~= "" and "AtlasTextMuted" or nil,
		},
	}

	return rows
end

--------------------------------------------------------------------------------
-- Chips: labels
--------------------------------------------------------------------------------

---@param hex string|nil
---@return string
local function label_hl(hex)
	local clean = tostring(hex or ""):lower():gsub("[^0-9a-f]", "")
	if #clean ~= 6 then
		return "AtlasChipActive"
	end
	local name = "AtlasGHIssueLabel_" .. clean
	vim.api.nvim_set_hl(0, name, { fg = "#000000", bg = "#" .. clean, bold = true })
	return name
end

---@param issue Issue
---@return IssuesPanelChip[]
function M.chips(issue)
	local chips = {}
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local labels = type(raw.labels) == "table" and raw.labels or {}
	for _, label in ipairs(labels) do
		local name = tostring(label.name or "")
		if name ~= "" then
			table.insert(chips, { label = name, hl = label_hl(label.color) })
		end
	end

	return chips
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

---@param _issue Issue
---@return boolean
function M.is_loading(_issue)
	return conversation_state.any_loading() or activity_state.any_loading()
end

---@return IssuesPanelTab[]
function M.tabs()
	return {
		{
			key = "conversation",
			label = "Conversation",
			icon = icons.general("comment"),
			mod = require("atlas.issues.providers.github.ui.conversation"),
		},
		{
			key = "activity",
			label = "Activity",
			icon = icons.pulls("activity"),
			mod = require("atlas.issues.providers.github.ui.activity"),
		},
	}
end

return M
