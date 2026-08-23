---@type IssuesProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")
local helper = require("atlas.issues.ui.dashboard.helper")
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

---@param assignees IssueUser[]
---@return string, string|table[]
local function assignees_display(assignees)
	local usernames = {}
	for _, assignee in ipairs(assignees) do
		local username = tostring(assignee.account_id or assignee.display_name or "")
		if username ~= "" then
			table.insert(usernames, username)
		end
	end

	if #usernames == 0 then
		return "Unassigned", "AtlasTextMuted"
	end

	local parts = {}
	local spans = {}
	local cursor = 0
	for i, username in ipairs(usernames) do
		local token = "@" .. username
		table.insert(parts, token)
		table.insert(spans, {
			start_col = cursor,
			end_col = cursor + #token,
			hl_group = helper.person_hl(username),
		})
		cursor = cursor + #token

		if i < #usernames then
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

	local percent = tonumber(milestone.progress_percentage)
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

-- Header rows

---@param issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesDetailHeaderRow[]
function M.header_rows(issue, details, loading)
	local data = details or issue
	local reporter_name = data.reporter and tostring(data.reporter.display_name or "") or ""
	if reporter_name == "" then
		reporter_name = "Unknown"
	end

	local status_cell = {
		k1 = "Status:",
		v1 = tostring(data.status or "Open"),
		v1_hl = data.status_id == "closed" and "AtlasGHIssueClosedChip" or "AtlasGHIssueOpenChip",

		k2 = "Reporter:",
		v2 = string.format("%s %s", icons.general("user"), reporter_name),
		v2_hl = helper.person_hl(reporter_name),
	}

	local assignees = details and details.assignees or (issue.assignee and { issue.assignee } or {})
	local assignees_text, assignees_hl = assignees_display(assignees)
	if loading and details == nil then
		assignees_text = spinner.with_text("Loading...")
		assignees_hl = "AtlasTextMuted"
	end

	local right_cells = {}
	local parent = data.parent
	if parent and parent.key then
		local pkey = tostring(parent.key)
		local title = tostring(parent.title or "")
		local text = title ~= "" and string.format("%s %s", pkey, title) or pkey
		local hl = helper.issue_hl and helper.issue_hl(pkey) or "AtlasTextMuted"
		table.insert(right_cells, { k = "Parent:", v = text, hl = hl })
	end

	local milestone_text = milestone_display(details and details.milestone or nil)
	if milestone_text ~= "" then
		table.insert(right_cells, { k = "Milestone:", v = milestone_text, hl = "AtlasTextMuted" })
	end

	local subs = details and details.sub_issues or {}
	if #subs > 0 then
		local closed = 0
		for _, s in ipairs(subs) do
			if s.status_id == "closed" then
				closed = closed + 1
			end
		end
		table.insert(right_cells, {
			k = "Sub-issues:",
			v = string.format("%s %d/%d", icons.issues("issue"), closed, #subs),
			hl = closed == #subs and "AtlasTextPositive" or "AtlasTextMuted",
		})
	end

	local completed, total = task_progress(details and details.description or nil)
	if total > 0 then
		table.insert(right_cells, {
			k = "Tasks:",
			v = string.format("%s %d/%d", icons.pulls("tasks"), completed, total),
			hl = completed == total and "AtlasTextPositive" or "AtlasTextWarning",
		})
	end

	local function pop_right()
		local c = table.remove(right_cells, 1)
		if c == nil then
			return "", "", nil
		end
		return c.k, c.v, c.hl
	end

	local rk, rv, rh = pop_right()
	local rows = {
		status_cell,
		{ k1 = "Assignee:", v1 = assignees_text, v1_hl = assignees_hl, k2 = rk, v2 = rv, v2_hl = rh },
	}

	while #right_cells > 0 do
		local k, v, hl = pop_right()
		table.insert(rows, { k1 = "", v1 = "", v1_hl = nil, k2 = k, v2 = v, v2_hl = hl })
	end

	return rows
end

-- Chips: labels

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

---@return IssuesDetailTab[]
function M.tabs()
	local conversation_icon, conversation_hl = icons.general("conversation")
	return {
		{
			key = "conversation",
			label = "Conversation",
			icon = conversation_icon,
			icon_hl = conversation_hl,
			mod = require("atlas.issues.ui.detail.tabs.conversation"),
		},
	}
end

return M
