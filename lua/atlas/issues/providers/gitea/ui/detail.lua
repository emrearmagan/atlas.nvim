---@type IssuesProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.issues.ui.presentation")
local spinner = require("atlas.ui.components.spinner")

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

---@param assignees IssueUser[]
---@return string, string|table[]
local function assignees_display(assignees)
	local parts, spans = {}, {}
	local cursor = 0
	for _, assignee in ipairs(assignees) do
		local login = tostring(assignee.account_id or assignee.display_name or "")
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

---@param issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesDetailHeaderField[]
function M.header_fields(issue, details, loading)
	---@cast issue GiteaIssue
	---@cast details GiteaIssueDetails|nil
	local reporter = issue.reporter and tostring(issue.reporter.display_name or "") or ""
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
			hl = issue.status_id == "closed" and "AtlasGiteaIssueClosedChip" or "AtlasGiteaIssueOpenChip",
		},
		{
			label = "Author",
			value = string.format("%s %s", icons.general("user"), reporter),
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
	---@cast details GiteaIssueDetails|nil
	if loading then
		return { { label = spinner.with_text("Loading..."), hl = "AtlasTextMuted" } }
	end
	local chips = {}
	for _, label in ipairs(details and details.labels or {}) do
		if tostring(label.name or "") ~= "" then
			table.insert(chips, { label = label.name, hl = label_hl(label.color) })
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
