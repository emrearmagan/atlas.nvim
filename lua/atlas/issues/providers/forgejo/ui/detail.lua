---@type IssuesProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.issues.ui.presentation")
local spinner = require("atlas.ui.components.spinner")

---@param issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesDetailHeaderField[]
function M.header_fields(issue, details, loading)
	---@cast issue ForgejoIssue
	---@cast details ForgejoIssueDetails|nil
	local reporter = issue.reporter and tostring(issue.reporter.display_name or "") or ""
	if reporter == "" then
		reporter = "Unknown"
	end

	local assignees = {}
	for _, value in ipairs(details and details.assignees or (issue.assignee and { issue.assignee } or {})) do
		local login = tostring(value.account_id or "")
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

	local fields = {
		{
			label = "Status",
			value = tostring(issue.status or "Open"),
			hl = issue.status_id == "closed" and "AtlasForgejoIssueClosedChip" or "AtlasForgejoIssueOpenChip",
		},
		{
			label = "Author",
			value = string.format("%s %s", icons.general("user"), reporter),
			hl = helper.person_hl(reporter),
		},
		{ label = "Assignees", value = assignee_text, hl = assignee_hl },
	}

	local milestone = details and details.milestone and tostring(details.milestone.title or "") or ""
	if milestone ~= "" then
		table.insert(fields, { label = "Milestone", value = milestone, hl = "AtlasTextMuted" })
	end
	local created_at = issue.created_at or ""
	if created_at ~= "" then
		table.insert(fields, {
			label = "Opened",
			value = utils.relative_time_text(created_at) or created_at,
			hl = "AtlasTextMuted",
		})
	end
	if issue.duedate then
		table.insert(fields, { label = "Due", value = issue.duedate, hl = "AtlasTextWarning" })
	end
	return fields
end

---@param hex string|nil
---@return string
local function label_hl(hex)
	local clean = tostring(hex or ""):lower():gsub("[^0-9a-f]", "")
	if #clean ~= 6 then
		return "AtlasChipActive"
	end
	local name = "AtlasForgejoIssueLabel_" .. clean
	local r = tonumber(clean:sub(1, 2), 16) or 0
	local g = tonumber(clean:sub(3, 4), 16) or 0
	local b = tonumber(clean:sub(5, 6), 16) or 0
	local foreground = (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.6 and "#1e1e2e" or "#ffffff"
	vim.api.nvim_set_hl(0, name, { fg = foreground, bg = "#" .. clean, bold = true })
	return name
end

---@param _issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesDetailChip[]
function M.chips(_issue, details, loading)
	---@cast _issue ForgejoIssue
	---@cast details ForgejoIssueDetails|nil
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

---@return IssuesDetailTabDefinition[]
function M.tabs()
	local overview_icon, overview_hl = icons.general("overview")
	local conversation_icon, conversation_hl = icons.general("conversation")
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

return M
