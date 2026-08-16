---@class GiteaIssuesProviderPanel : IssuesProviderPanel
local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.issues.ui.main.helper")

---@param status_id string|nil
---@return string
local function state_chip_hl(status_id)
	return status_id == "closed" and "AtlasGiteaIssueClosedChip" or "AtlasGiteaIssueOpenChip"
end

---@param hex string|nil
---@return string
local function label_hl(hex)
	local clean = tostring(hex or ""):lower():gsub("[^0-9a-f]", "")
	if #clean ~= 6 then
		return "AtlasChipActive"
	end
	local name = "AtlasGiteaIssueLabel_" .. clean
	local r = tonumber(clean:sub(1, 2), 16) or 0
	local g = tonumber(clean:sub(3, 4), 16) or 0
	local b = tonumber(clean:sub(5, 6), 16) or 0
	local foreground = (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.6 and "#1e1e2e" or "#ffffff"
	vim.api.nvim_set_hl(0, name, { fg = foreground, bg = "#" .. clean, bold = true })
	return name
end

---@param issue Issue
---@param _loading boolean
---@return IssuesPanelHeaderRow[]
function M.header_rows(issue, _loading)
	local raw = issue._raw or {}
	local reporter = issue.reporter and tostring(issue.reporter.display_name or "") or ""
	if reporter == "" then
		reporter = "Unknown"
	end

	local assignees = {}
	for _, value in ipairs(type(raw.assignees) == "table" and raw.assignees or {}) do
		local login = tostring(value.login or "")
		if login ~= "" then
			table.insert(assignees, "@" .. login)
		end
	end
	local assignee_text = #assignees > 0 and table.concat(assignees, ", ") or "Unassigned"
	local milestone = type(raw.milestone) == "table" and tostring(raw.milestone.title or "") or ""
	local rows = {
		{
			k1 = "Status:",
			v1 = tostring(issue.status or "Open"),
			v1_hl = state_chip_hl(issue.status_id),
			k2 = "Author:",
			v2 = string.format("%s %s", icons.general("user"), reporter),
			v2_hl = helper.person_hl(reporter),
		},
		{
			k1 = "Assignees:",
			v1 = assignee_text,
			v1_hl = #assignees > 0 and helper.person_hl(assignees[1]:sub(2)) or "AtlasTextMuted",
			k2 = milestone ~= "" and "Milestone:" or "",
			v2 = milestone,
			v2_hl = milestone ~= "" and "AtlasTextMuted" or nil,
		},
	}

	if type(raw.created_at) == "string" and raw.created_at ~= "" then
		table.insert(rows, {
			k1 = "Opened:",
			v1 = utils.relative_time_text(raw.created_at) or raw.created_at,
			v1_hl = "AtlasTextMuted",
			k2 = issue.duedate and "Due:" or "",
			v2 = issue.duedate or "",
			v2_hl = issue.duedate and "AtlasTextWarning" or nil,
		})
	end
	return rows
end

---@param issue Issue
---@param loading boolean
---@return IssuesPanelChip[]
function M.chips(issue, loading)
	local chips = {}
	if loading then
		local spinner = require("atlas.ui.components.spinner")
		table.insert(chips, { label = spinner.with_text("Loading..."), hl = "AtlasTextMuted" })
		return chips
	end
	for _, label in ipairs(type(issue._raw) == "table" and issue._raw.labels or {}) do
		local name = tostring(label.name or "")
		if name ~= "" then
			table.insert(chips, { label = name, hl = label_hl(label.color) })
		end
	end
	return chips
end

---@param issue Issue
---@param _opts { force_refresh: boolean|nil, issue_refreshed: boolean|nil }|nil
---@param on_done fun()
---@return { cancel: fun() }|nil
function M.fetch_header(issue, _opts, on_done)
	return require("atlas.issues.providers.gitea.api").issues.check_subscription(issue.key, function(subscribed, err)
		if not err then
			issue.is_subscribed = subscribed
		end
		on_done()
	end)
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
