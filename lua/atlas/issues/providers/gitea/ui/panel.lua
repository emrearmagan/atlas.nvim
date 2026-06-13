---@class GiteaIssuesProviderPanel : IssuesProviderPanel
local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.issues.ui.main.helper")

---@param status_id string|nil
---@return string
local function state_chip_hl(status_id)
	if status_id == "closed" then
		return "AtlasGiteaIssueClosedChip"
	end
	return "AtlasGiteaIssueOpenChip"
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
	local lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255
	local fg = lum > 0.6 and "#1e1e2e" or "#ffffff"
	vim.api.nvim_set_hl(0, name, { fg = fg, bg = "#" .. clean, bold = true })
	return name
end

local state = {
	labels = nil, ---@type table|nil
	milestone = nil, ---@type table|nil
	assignees = nil, ---@type table|nil
	body = nil, ---@type string|nil
	detail_loading = false,
}

local function reset_state()
	state.labels = nil
	state.milestone = nil
	state.assignees = nil
	state.body = nil
	state.detail_loading = false
end

--------------------------------------------------------------------------------
-- Header rows
--------------------------------------------------------------------------------

---@param issue Issue
---@return IssuesPanelHeaderRow[]
function M.header_rows(issue)
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local user_icon = icons.general("user")

	local reporter_name = type(issue.reporter) == "table" and tostring(issue.reporter.display_name or "") or ""
	if reporter_name == "" then
		reporter_name = "Unknown"
	end

	-- Assignees
	local assignees_nodes = state.assignees or raw.assignees or {}
	local assignee_logins = {}
	for _, a in ipairs(assignees_nodes) do
		local login = tostring(a.login or a.account_id or "")
		if login ~= "" then
			table.insert(assignee_logins, "@" .. login)
		end
	end
	local assignees_text = #assignee_logins > 0 and table.concat(assignee_logins, ", ") or "Unassigned"
	local assignees_hl = #assignee_logins > 0
		and (helper.person_hl and helper.person_hl(assignee_logins[1]:sub(2)) or "Normal")
		or "AtlasTextMuted"

	-- Milestone
	local milestone = state.milestone or raw.milestone
	local milestone_text = ""
	if type(milestone) == "table" and type(milestone.title) == "string" then
		milestone_text = milestone.title
	end

	local rows = {
		{
			k1 = "Status:",
			v1 = tostring(issue.status or "Open"),
			v1_hl = state_chip_hl(issue.status_id),
			k2 = "Reporter:",
			v2 = string.format("%s %s", user_icon, reporter_name),
			v2_hl = helper.person_hl and helper.person_hl(reporter_name) or "Normal",
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

	if raw.created_at and raw.created_at ~= "" then
		local rel = utils.relative_time_text and utils.relative_time_text(raw.created_at) or raw.created_at
		table.insert(rows, {
			k1 = "Opened:",
			v1 = rel or raw.created_at,
			v1_hl = "AtlasTextMuted",
			k2 = "",
			v2 = "",
			v2_hl = nil,
		})
	end

	return rows
end

--------------------------------------------------------------------------------
-- Chips: labels
--------------------------------------------------------------------------------

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
	for _, lbl in ipairs(labels) do
		local name = tostring(lbl.name or "")
		if name ~= "" then
			table.insert(chips, { label = name, hl = label_hl(lbl.color) })
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
	return state.detail_loading
		or (type(conversation_state.any_loading) == "function" and conversation_state.any_loading())
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

	local issues_api = require("atlas.issues.providers.gitea.api.issues")
	issues_api.get_issue(key, { force_load = opts and opts.force_load == true or false }, function(fresh, err)
		state.detail_loading = false
		if not err and type(fresh) == "table" then
			local fraw = fresh._raw or {}
			state.labels = fraw.labels
			state.milestone = fraw.milestone
			state.assignees = fraw.assignees
			state.body = fraw.body
			issue._raw = fresh._raw
		end
		refresh()
	end)
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
