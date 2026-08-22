---@class GitLabIssuesProviderPanel : IssuesProviderPanel
local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.issues.ui.main.helper")
local spinner = require("atlas.ui.components.spinner")

---@param status_id string|nil
---@return string
local function state_chip_hl(status_id)
	if status_id == "closed" then
		return "AtlasGLIssueClosedChip"
	end
	return "AtlasGLIssueOpenChip"
end

---@param milestone IssueMilestone|nil
---@return string
local function milestone_display(milestone)
	if milestone == nil then
		return ""
	end
	local title = tostring(milestone.title or "")
	if title == "" then
		return ""
	end
	return title
end

---@param issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesPanelHeaderRow[]
function M.header_rows(issue, details, loading)
	local data = details or issue
	local user_icon = icons.general("user")

	local assignee_name = data.assignee and tostring(data.assignee.display_name or "") or ""
	local reporter_name = data.reporter and tostring(data.reporter.display_name or "") or ""
	if assignee_name == "" then
		assignee_name = "Unassigned"
	end
	if reporter_name == "" then
		reporter_name = "Unknown"
	end

	local milestone_text = milestone_display(details and details.milestone or nil)
	local assignee_text = string.format("%s %s", user_icon, assignee_name)
	local assignee_hl = helper.person_hl(data.assignee and data.assignee.display_name or nil)
	if loading and details == nil then
		assignee_text = spinner.with_text("Loading...")
		assignee_hl = "AtlasTextMuted"
	end

	local rows = {
		{
			k1 = "Status:",
			v1 = tostring(data.status or "Open"),
			v1_hl = state_chip_hl(data.status_id),
			k2 = "Author:",
			v2 = string.format("%s %s", user_icon, reporter_name),
			v2_hl = helper.person_hl(reporter_name),
		},
		{
			k1 = "Assignee:",
			v1 = assignee_text,
			v1_hl = assignee_hl,
			k2 = milestone_text ~= "" and "Milestone:" or "",
			v2 = milestone_text,
			v2_hl = milestone_text ~= "" and "AtlasTextMuted" or nil,
		},
	}

	local created_at = details and details.created_at or ""
	if created_at ~= "" then
		table.insert(rows, {
			k1 = "Opened:",
			v1 = utils.relative_time_text(created_at) or created_at,
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

---@param _issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesPanelChip[]
function M.chips(_issue, details, loading)
	local chips = {}
	if loading then
		table.insert(chips, { label = spinner.with_text("Loading..."), hl = "AtlasTextMuted" })
		return chips
	end

	for _, label in ipairs(details and details.labels or {}) do
		local name = tostring(label.name or "")
		if name ~= "" then
			table.insert(chips, { label = name, hl = label_hl(label.color) })
		end
	end
	return chips
end

---@return IssuesPanelTab[]
function M.tabs()
	local conversation_icon, conversation_hl = icons.general("conversation")
	local activity_icon, activity_hl = icons.pulls("activity")
	return {
		{
			key = "conversation",
			label = "Conversation",
			icon = conversation_icon,
			icon_hl = conversation_hl,
			mod = require("atlas.issues.ui.panel.issue.tabs.conversation"),
		},
		{
			key = "activity",
			label = "Activity",
			icon = activity_icon,
			icon_hl = activity_hl,
			mod = require("atlas.issues.ui.panel.issue.tabs.activity"),
		},
	}
end

return M
