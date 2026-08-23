---@class ForgejoIssuesProviderPanel : IssuesProviderPanel
local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.issues.ui.main.helper")
local issues_api = require("atlas.issues.providers.forgejo.api.issues")
local spinner = require("atlas.ui.components.spinner")

---@param status_id string|nil
---@return string
local function state_chip_hl(status_id)
	return status_id == "closed" and "AtlasForgejoIssueClosedChip" or "AtlasForgejoIssueOpenChip"
end

---@param hex string|nil
---@return string
local function label_hl(hex)
	local clean = (hex or ""):lower():gsub("[^0-9a-f]", "")
	if #clean ~= 6 then
		return "AtlasChipActive"
	end
	local name = "AtlasForgejoIssueLabel_" .. clean
	local r = tonumber(clean:sub(1, 2), 16)
	local g = tonumber(clean:sub(3, 4), 16)
	local b = tonumber(clean:sub(5, 6), 16)
	---@cast r number
	---@cast g number
	---@cast b number
	local foreground = (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.6 and "#1e1e2e" or "#ffffff"
	vim.api.nvim_set_hl(0, name, { fg = foreground, bg = "#" .. clean, bold = true })
	return name
end

---@param issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesPanelHeaderRow[]
function M.header_rows(issue, details, loading)
	local data = details or issue
	local reporter = data.reporter and data.reporter.display_name or ""
	if reporter == "" then
		reporter = "Unknown"
	end

	local assignees = {}
	for _, value in ipairs(details and details.assignees or (issue.assignee and { issue.assignee } or {})) do
		local login = value.account_id
		if login ~= "" then
			table.insert(assignees, "@" .. login)
		end
	end
	local assignee_text = #assignees > 0 and table.concat(assignees, ", ") or "Unassigned"
	local assignee_hl = #assignees > 0 and helper.person_hl(assignees[1]:sub(2)) or "AtlasTextMuted"
	if loading and details == nil then
		assignee_text = spinner.with_text("Loading...")
		assignee_hl = "AtlasTextMuted"
	end
	local milestone = details and details.milestone and details.milestone.title or ""
	local rows = {
		{
			k1 = "Status:",
			v1 = data.status,
			v1_hl = state_chip_hl(data.status_id),
			k2 = "Author:",
			v2 = string.format("%s %s", icons.general("user"), reporter),
			v2_hl = helper.person_hl(reporter),
		},
		{
			k1 = "Assignees:",
			v1 = assignee_text,
			v1_hl = assignee_hl,
			k2 = milestone ~= "" and "Milestone:" or "",
			v2 = milestone,
			v2_hl = milestone ~= "" and "AtlasTextMuted" or nil,
		},
	}

	local created_at = details and details.created_at or ""
	if created_at ~= "" then
		table.insert(rows, {
			k1 = "Opened:",
			v1 = utils.relative_time_text(created_at) or created_at,
			v1_hl = "AtlasTextMuted",
			k2 = data.duedate and "Due:" or "",
			v2 = data.duedate or "",
			v2_hl = data.duedate and "AtlasTextWarning" or nil,
		})
	end
	return rows
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
		local name = label.name
		if name ~= "" then
			table.insert(chips, { label = name, hl = label_hl(label.color) })
		end
	end
	return chips
end

---@return IssuesPanelTab[]
function M.tabs()
	local conversation_icon, conversation_hl = icons.general("conversation")
	return {
		{
			key = "conversation",
			label = "Conversation",
			icon = conversation_icon,
			icon_hl = conversation_hl,
			mod = require("atlas.issues.ui.panel.issue.tabs.conversation"),
		},
	}
end

---@param issue Issue
---@param details IssueDetails
---@param _ { force_refresh: boolean|nil }|nil
---@param on_done fun()
---@return { cancel: fun() }|nil
function M.fetch_header(issue, details, _, on_done)
	return issues_api.check_subscription(details.key, function(subscribed, err)
		if not err then
			issue.is_subscribed = subscribed
			details.is_subscribed = subscribed
		end
		on_done()
	end)
end

return M
