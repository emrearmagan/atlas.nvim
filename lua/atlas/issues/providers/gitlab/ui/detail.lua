---@type IssuesProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.issues.ui.presentation")
local spinner = require("atlas.ui.components.spinner")

---@param status_id string|nil
---@return string
local function state_chip_hl(status_id)
	if status_id == "closed" then
		return "AtlasIssueClosedChip"
	end
	return "AtlasIssueOpenChip"
end

---@param issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesDetailHeaderField[]
function M.header_fields(issue, details, _loading)
	local user_icon = icons.general("user")

	local assignee = details and details.assignees[1] or issue.assignee
	local assignee_name = assignee and tostring(assignee.display_name or "") or ""
	local reporter_name = issue.reporter and tostring(issue.reporter.display_name or "") or ""
	if assignee_name == "" then
		assignee_name = "Unassigned"
	end
	if reporter_name == "" then
		reporter_name = "Unknown"
	end

	local milestone_text = details and details.milestone and details.milestone.title or ""
	local assignee_text = string.format("%s %s", user_icon, assignee_name)
	local assignee_hl = helper.person_hl(assignee and assignee.display_name or nil)

	local fields = {
		{
			label = "Status",
			value = tostring(issue.status or "Open"),
			hl = state_chip_hl(issue.status_id),
		},
		{
			label = "Author",
			value = string.format("%s %s", user_icon, reporter_name),
			hl = helper.person_hl(reporter_name),
		},
		{ label = "Assignee", value = assignee_text, hl = assignee_hl },
	}
	if milestone_text ~= "" then
		table.insert(fields, { label = "Milestone", value = milestone_text, hl = "AtlasTextMuted" })
	end

	local created_at = issue.created_at or ""
	if created_at ~= "" then
		table.insert(fields, {
			label = "Opened",
			value = utils.relative_time_text(created_at) or created_at,
			hl = "AtlasTextMuted",
		})
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
---@return IssuesDetailChip[]
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
