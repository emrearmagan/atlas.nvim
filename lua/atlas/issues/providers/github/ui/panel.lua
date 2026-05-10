---@class GitHubIssuesProviderPanel : IssuesProviderPanel
local M = {}

local icons = require("atlas.ui.shared.icons")
local table_tree = require("atlas.ui.components.table_tree")
local helper = require("atlas.issues.ui.main.helper")
local conversation_state = require("atlas.issues.providers.github.ui.conversation.state")
local activity_state = require("atlas.issues.providers.github.ui.activity.state")

local function text_or(v, fallback)
	if type(v) == "string" and v ~= "" then
		return v
	end
	return fallback
end

---@param text string
---@param hl string|table[]|nil
---@return table[]|nil
local function value_hl_spans(text, hl)
	if type(hl) == "table" then
		return #hl > 0 and hl or nil
	end
	if type(hl) == "string" and hl ~= "" then
		return { { start_col = 0, end_col = #text, hl_group = hl } }
	end
	return nil
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

---@param issue Issue
---@return string, string|table[]
local function assignees_display(issue)
	local raw = type(issue._raw) == "table" and issue._raw or {}
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

---@param status_id string|nil
---@return string, string
local function state_icon_and_hl(status_id)
	if status_id == "closed" then
		return icons.pulls_status("successful"), "AtlasGHIssueClosed"
	end
	return icons.issues("issue"), "AtlasGHIssueOpen"
end

---@param status_id string|nil
---@return string
local function state_chip_hl(status_id)
	if status_id == "closed" then
		return "AtlasGHIssueClosedChip"
	end
	return "AtlasGHIssueOpenChip"
end

--------------------------------------------------------------------------------
-- Header (full override)
--------------------------------------------------------------------------------

---@param issue Issue
---@param width integer
---@return string[], table[]
function M.render_header(issue, width)
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local number = raw.number or 0
	local slug = tostring(raw.slug or "")
	local title = text_or(issue.summary, "")
	local status_label = text_or(issue.status, "Open")
	local s_icon, s_hl = state_icon_and_hl(issue.status_id)
	local status_hl = state_chip_hl(issue.status_id)
	local key_label = slug ~= "" and string.format("%s#%d", slug, number) or string.format("#%d", number)

	local first_line = string.format(" %s %s %s", s_icon, status_label, key_label)
	local title_line = " " .. title

	local reporter_name = type(issue.reporter) == "table" and issue.reporter.display_name or "Unknown"
	local assignees_text, assignees_hl = assignees_display(issue)
	local user_icon = icons.general("user")

	local rows = {
		{
			k1 = "Author:",
			v1 = string.format("%s %s", user_icon, reporter_name),
			v1_hl = helper.person_hl(reporter_name),
			k2 = "Assignees:",
			v2 = assignees_text,
			v2_hl = assignees_hl,
		},
	}

	if raw.created_at and raw.created_at ~= "" then
		local utils = require("atlas.ui.shared.utils")
		table.insert(rows, {
			k1 = "Opened:",
			v1 = utils.relative_time_text(raw.created_at) or raw.created_at,
			v1_hl = "AtlasTextMuted",
			k2 = "",
			v2 = "",
			v2_hl = nil,
		})
	end

	local table_lines, _, table_spans = table_tree.render({
		columns = {
			{ key = "k1", name = "", can_grow = false },
			{ key = "v1", name = "", can_grow = true },
			{ key = "k2", name = "", can_grow = false },
			{ key = "v2", name = "", can_grow = true, grow_last = true },
		},
		rows = rows,
		width = width,
		margin = 1,
		show_header = false,
		column_gap = 2,
		fill = true,
		cell_hl = function(row, col)
			if col.key == "k1" or col.key == "k2" then
				local label = col.key == "k1" and row.k1 or row.k2
				return { { start_col = 0, end_col = #label, hl_group = "AtlasTextMuted" } }
			end
			if col.key == "v1" then
				return value_hl_spans(row.v1, row.v1_hl)
			end
			if col.key == "v2" and row.v2 ~= "" then
				return value_hl_spans(row.v2, row.v2_hl)
			end
		end,
	})

	local lines = { first_line, title_line, "" }
	for _, l in ipairs(table_lines) do
		table.insert(lines, l)
	end
	table.insert(lines, "")

	local spans = {
		{ line = 0, line_hl_group = "AtlasPanelHeaderBg" },
		{ line = 1, line_hl_group = "AtlasPanelHeaderBg" },
		{ line = 0, start_col = 1, end_col = 1 + #s_icon, hl_group = s_hl },
		{ line = 0, start_col = 1 + #s_icon + 1, end_col = 1 + #s_icon + 1 + #status_label, hl_group = status_hl },
		{ line = 0, start_col = #first_line - #key_label, end_col = #first_line, hl_group = "AtlasGHIssueKey" },
		{ line = 1, start_col = 1, end_col = #title_line, hl_group = "Normal" },
	}

	for _, span in ipairs(table_spans) do
		table.insert(spans, {
			line = span.line + 3,
			start_col = span.start_col,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end

	return lines, spans
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
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local labels = type(raw.labels) == "table" and raw.labels or {}
	for _, label in ipairs(labels) do
		local name = tostring(label.name or "")
		if name ~= "" then
			table.insert(chips, { label = name, hl = label_hl(label.color) })
		end
	end

	local milestone = type(raw.milestone) == "table" and raw.milestone or nil
	if milestone and tostring(milestone.title or "") ~= "" then
		table.insert(chips, {
			label = string.format("%s %s", icons.pulls("activity"), milestone.title),
			hl = "AtlasChipActive",
		})
	end
	return chips
end

--------------------------------------------------------------------------------
-- Loading + tabs
--------------------------------------------------------------------------------

---@param _issue Issue
---@return boolean
function M.is_loading(_issue)
	return conversation_state.any_loading() or activity_state.any_loading()
end

---@return IssuesPanelTab[]
function M.tabs()
	return {
		{
			key = "conversation",
			label = "Conversation",
			icon = icons.general("comment"),
			mod = require("atlas.issues.providers.github.ui.conversation"),
		},
		{
			key = "activity",
			label = "Activity",
			icon = icons.pulls("activity"),
			mod = require("atlas.issues.providers.github.ui.activity"),
		},
	}
end

return M
