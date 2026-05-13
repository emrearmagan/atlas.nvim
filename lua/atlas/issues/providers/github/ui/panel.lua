---@class GitHubIssuesProviderPanel : IssuesProviderPanel
local M = {}

local icons = require("atlas.ui.shared.icons")
local helper = require("atlas.issues.ui.main.helper")
local conversation_state = require("atlas.issues.providers.github.ui.conversation.state")
local history_state = require("atlas.issues.ui.panel.issue.tabs.activity.state")

local state = {
	assignees = nil, ---@type table|nil
	labels = nil, ---@type table|nil
	milestone = nil, ---@type table|nil
	sub_issues = nil, ---@type table|nil
	body = nil, ---@type string|nil
	parent = nil, ---@type Issue|nil
	detail_loading = false,
}

local function reset_state()
	state.assignees = nil
	state.labels = nil
	state.milestone = nil
	state.sub_issues = nil
	state.body = nil
	state.parent = nil
	state.detail_loading = false
end

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

	local reporter_name = type(issue.reporter) == "table" and tostring(issue.reporter.display_name or "") or ""
	if reporter_name == "" then
		reporter_name = "Unknown"
	end

	local status_cell = {
		k1 = "Status:",
		v1 = tostring(issue.status or "Open"),
		v1_hl = issue.status_id == "closed" and "AtlasGHIssueClosedChip" or "AtlasGHIssueOpenChip",

		k2 = "Reporter:",
		v2 = string.format("%s %s", icons.general("user"), reporter_name),
		v2_hl = helper.person_hl(reporter_name),
	}

	local assignees_text, assignees_hl = assignees_display({ assignees = state.assignees or raw.assignees })

	local right_cells = {}
	local parent = state.parent or issue.parent
	if type(parent) == "table" and parent.key then
		local pkey = tostring(parent.key)
		local title = tostring(parent.summary or "")
		local text = title ~= "" and string.format("%s %s", pkey, title) or pkey
		local hl = helper.issue_hl and helper.issue_hl(pkey) or "AtlasTextMuted"
		table.insert(right_cells, { k = "Parent:", v = text, hl = hl })
	end

	local milestone_text = milestone_display(state.milestone or raw.milestone)
	if milestone_text ~= "" then
		table.insert(right_cells, { k = "Milestone:", v = milestone_text, hl = "AtlasTextMuted" })
	end

	local subs = type(state.sub_issues) == "table" and state.sub_issues or {}
	if #subs > 0 then
		local closed = 0
		for _, s in ipairs(subs) do
			if tostring(s.state or ""):upper() == "CLOSED" then
				closed = closed + 1
			end
		end
		table.insert(right_cells, {
			k = "Sub-issues:",
			v = string.format("%s %d/%d", icons.issues("issue"), closed, #subs),
			hl = closed == #subs and "AtlasTextPositive" or "AtlasTextMuted",
		})
	end

	local completed, total = task_progress(state.body or raw.body)
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
	if state.detail_loading then
		local spinner = require("atlas.ui.components.spinner")
		table.insert(chips, { label = spinner.with_text("Loading..."), hl = "AtlasTextMuted" })
		return chips
	end

	local raw = type(issue._raw) == "table" and issue._raw or {}
	local labels = state.labels or raw.labels or {}
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
	return state.detail_loading or conversation_state.any_loading() or history_state.any_loading()
end

---@param issue Issue
---@param refresh fun()
---@param opts { force_load?: boolean }|nil
function M.fetches(issue, refresh, opts)
	local key = tostring(issue.key or "")
	if key == "" then
		return
	end

	reset_state()
	state.detail_loading = true

	local issues_api = require("atlas.issues.providers.github.api.issues")
	issues_api.get_issue(key, function(fresh, err)
		state.detail_loading = false
		if not err and type(fresh) == "table" then
			local fraw = fresh._raw or {}
			state.assignees = fraw.assignees
			state.labels = fraw.labels
			state.milestone = fraw.milestone
			state.sub_issues = fraw.sub_issues
			state.body = fraw.body
			state.parent = fresh.parent
			issue.is_subscribed = fresh.is_subscribed
			issue._raw = fresh._raw
		end
		refresh()
	end, { force_load = opts and opts.force_load == true or false })
end

---@return IssuesPanelTab[]
function M.tabs()
	return {
		{
			key = "conversation",
			label = "Conversation",
			icon = icons.general("conversation"),
			mod = require("atlas.issues.providers.github.ui.conversation"),
		},
		{
			key = "activity",
			label = "Activity",
			icon = icons.pulls("activity"),
			mod = require("atlas.issues.ui.panel.issue.tabs.activity"),
		},
	}
end

---@param item IssueHistoryItem
---@return { label: string, content: string|nil }
function M.format_history_item(item)
	local label, content = require("atlas.issues.providers.github.ui.event_label").format(item)
	return { label = label, content = content }
end

---@param item IssueHistoryItem
---@param row string
---@param row_index integer
---@return table[]|nil
function M.history_item_hl(item, row, row_index) ---@diagnostic disable-line: unused-local
	local highlights = require("atlas.ui.shared.highlights")
	local field = item.field or ""
	local hl
	if field == "labeled" or field == "unlabeled" then
		hl = label_hl(item.label_color)
	elseif field == "assigned" or field == "unassigned" then
		hl = highlights.dynamic_for(item.assignee_login)
	elseif field == "milestoned" or field == "demilestoned" then
		hl = highlights.dynamic_for(item.milestone_title)
	elseif field == "closed" then
		hl = "AtlasGHIssueClosed"
	elseif field == "reopened" then
		hl = "AtlasGHIssueOpen"
	end
	return { { start_col = 0, end_col = #row, hl_group = hl or "AtlasTextMuted" } }
end

return M
