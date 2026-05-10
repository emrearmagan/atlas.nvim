---@class GitLabIssuesProviderPanel : IssuesProviderPanel
local M = {}

local icons = require("atlas.ui.shared.icons")
local table_tree = require("atlas.ui.components.table_tree")
local helper = require("atlas.issues.ui.main.helper")

local function text_or(v, fallback)
	if type(v) == "string" and v ~= "" then
		return v
	end
	return fallback
end

---@param status_id string|nil
---@return string, string
local function state_icon_and_hl(status_id)
	if status_id == "closed" then
		return icons.pulls_status("successful"), "AtlasGLIssueClosed"
	end
	return icons.pulls("issue"), "AtlasGLIssueOpen"
end

---@param issue Issue
---@param width integer
---@return string[], table[]
function M.render_header(issue, width)
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local iid = raw.iid or 0
	local path = tostring(raw.project_path or "")
	local title = text_or(issue.summary, "")
	local status_label = text_or(issue.status, "Open")
	local s_icon, s_hl = state_icon_and_hl(issue.status_id)
	local key_label = path ~= "" and string.format("%s#%d", path, iid) or string.format("#%d", iid)

	local first_line = string.format(" %s %s %s", s_icon, status_label, key_label)
	local title_line = " " .. title

	local assignee_name = type(issue.assignee) == "table" and issue.assignee.display_name or "Unassigned"
	local reporter_name = type(issue.reporter) == "table" and issue.reporter.display_name or "Unknown"
	local user_icon = icons.general("user")

	local rows = {
		{
			k1 = "Author:",
			v1 = string.format("%s %s", user_icon, reporter_name),
			v1_hl = helper.person_hl(reporter_name),
			k2 = "Assignee:",
			v2 = string.format("%s %s", user_icon, assignee_name),
			v2_hl = helper.person_hl(type(issue.assignee) == "table" and issue.assignee.display_name or nil),
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
				return { { start_col = 0, end_col = #row.v1, hl_group = row.v1_hl } }
			end
			if col.key == "v2" and row.v2 ~= "" then
				return { { start_col = 0, end_col = #row.v2, hl_group = row.v2_hl } }
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
		{ line = 0, start_col = 1 + #s_icon + 1, end_col = 1 + #s_icon + 1 + #status_label, hl_group = s_hl },
		{ line = 0, start_col = #first_line - #key_label, end_col = #first_line, hl_group = "AtlasGLIssueKey" },
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

---@param _issue Issue
---@return boolean
function M.is_loading(_issue)
	local overview_state = require("atlas.issues.ui.panel.issue.tabs.overview.state")
	local comments_state = require("atlas.issues.ui.panel.issue.tabs.comments.state")
	local history_state = require("atlas.issues.ui.panel.issue.tabs.history.state")
	return overview_state.description_loading == true
		or (type(comments_state.any_loading) == "function" and comments_state.any_loading())
		or (type(history_state.any_loading) == "function" and history_state.any_loading())
end

-- GitLab system notes are already human-readable strings ("added ~bug label",
-- "closed via merge request !42", etc.), so we just surface the body text.
---@param item IssueHistoryItem
---@return { label: string, content: string|nil }
function M.format_history_item(item)
	local body = tostring(item.to_string or item.from_string or item.field or "")
	return { label = body, content = nil }
end

---@return IssuesPanelTab[]
function M.tabs()
	return {
		{
			key = "overview",
			label = "Overview",
			icon = icons.general("overview"),
			mod = require("atlas.issues.ui.panel.issue.tabs.overview"),
		},
		{
			key = "comments",
			label = "Comments",
			icon = icons.general("comment"),
			mod = require("atlas.issues.ui.panel.issue.tabs.comments"),
		},
		{
			key = "history",
			label = "History",
			icon = icons.pulls("activity"),
			mod = require("atlas.issues.ui.panel.issue.tabs.history"),
		},
	}
end

return M
