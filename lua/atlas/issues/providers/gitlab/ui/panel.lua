---@class GitLabIssuesProviderPanel : IssuesProviderPanel
local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.issues.ui.main.helper")

---@param status_id string|nil
---@return string
local function state_chip_hl(status_id)
	if status_id == "closed" then
		return "AtlasGLIssueClosedChip"
	end
	return "AtlasGLIssueOpenChip"
end

---@param milestone any
---@return string
local function milestone_display(milestone)
	if type(milestone) ~= "table" then
		return ""
	end
	local title = tostring(milestone.title or "")
	if title == "" then
		return ""
	end
	return title
end

---@param issue Issue
---@return IssuesPanelHeaderRow[]
function M.header_rows(issue)
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local user_icon = icons.general("user")

	local assignee_name = type(issue.assignee) == "table" and tostring(issue.assignee.display_name or "") or ""
	local reporter_name = type(issue.reporter) == "table" and tostring(issue.reporter.display_name or "") or ""
	if assignee_name == "" then
		assignee_name = "Unassigned"
	end
	if reporter_name == "" then
		reporter_name = "Unknown"
	end

	local milestone_text = milestone_display(raw.milestone)

	local rows = {
		{
			k1 = "Status:",
			v1 = tostring(issue.status or "Open"),
			v1_hl = state_chip_hl(issue.status_id),
			k2 = "Author:",
			v2 = string.format("%s %s", user_icon, reporter_name),
			v2_hl = helper.person_hl(reporter_name),
		},
		{
			k1 = "Assignee:",
			v1 = string.format("%s %s", user_icon, assignee_name),
			v1_hl = helper.person_hl(type(issue.assignee) == "table" and issue.assignee.display_name or nil),
			k2 = milestone_text ~= "" and "Milestone:" or "",
			v2 = milestone_text,
			v2_hl = milestone_text ~= "" and "AtlasTextMuted" or nil,
		},
	}

	if raw.created_at and raw.created_at ~= "" then
		table.insert(rows, {
			k1 = "Opened:",
			v1 = utils.relative_time_text(raw.created_at) or raw.created_at,
			v1_hl = "AtlasTextMuted",
			k2 = "",
			v2 = "",
			v2_hl = nil,
		})
	end

	return rows
end

---@param hex string|nil
---@return string
local function label_hl(hex)
	local clean = tostring(hex or ""):lower():gsub("[^0-9a-f]", "")
	if #clean ~= 6 then
		return "AtlasChipActive"
	end
	local name = "AtlasGLIssueLabel_" .. clean
	local r = tonumber(clean:sub(1, 2), 16) or 0
	local g = tonumber(clean:sub(3, 4), 16) or 0
	local b = tonumber(clean:sub(5, 6), 16) or 0
	local lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255
	local fg = lum > 0.6 and "#1e1e2e" or "#ffffff"
	vim.api.nvim_set_hl(0, name, { fg = fg, bg = "#" .. clean, bold = true })
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
	local conversation_state = require("atlas.issues.ui.panel.issue.tabs.conversation.state")
	local history_state = require("atlas.issues.ui.panel.issue.tabs.activity.state")
	return (type(conversation_state.any_loading) == "function" and conversation_state.any_loading())
		or (type(history_state.any_loading) == "function" and history_state.any_loading())
end

---@return IssuesPanelTab[]
function M.tabs()
	return {
		{
			key = "conversation",
			label = "Conversation",
			icon = icons.general("conversation"),
			mod = require("atlas.issues.ui.panel.issue.tabs.conversation"),
		},
		{
			key = "activity",
			label = "Activity",
			icon = icons.pulls("activity"),
			mod = require("atlas.issues.ui.panel.issue.tabs.activity"),
		},
	}
end

return M
