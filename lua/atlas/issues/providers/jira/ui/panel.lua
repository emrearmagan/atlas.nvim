---@class JiraIssuesProviderPanel : IssuesProviderPanel
local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.issues.ui.main.helper")

local overview_state = require("atlas.issues.ui.panel.issue.tabs.overview.state")
local comments_state = require("atlas.issues.ui.panel.issue.tabs.comments.state")
local history_state = require("atlas.issues.ui.panel.issue.tabs.activity.state")

--------------------------------------------------------------------------------
-- Header rows
--------------------------------------------------------------------------------

---@param issue Issue
---@return IssuesPanelHeaderRow[]
function M.header_rows(issue)
	local user_icon = icons.general("user")
	local priority = tostring(issue.priority or "-")
	local priority_icon = icons.issues_priority(priority)
	local priority_text = priority_icon ~= "" and string.format("%s %s", priority_icon, priority) or priority
	local assignee_name = type(issue.assignee) == "table" and tostring(issue.assignee.display_name or "") or ""
	local reporter_name = type(issue.reporter) == "table" and tostring(issue.reporter.display_name or "") or ""

	if assignee_name == "" then
		assignee_name = "Unassigned"
	end
	if reporter_name == "" then
		reporter_name = "Unknown"
	end

	local rows = {
		{
			k1 = "Status:",
			v1 = tostring(issue.status or "Unknown"),
			v1_hl = helper.status_hl(issue.status_id),
			k2 = "Priority:",
			v2 = priority_text,
			v2_hl = helper.priority_hl(issue.priority),
		},
		{
			k1 = "Assignee:",
			v1 = assignee_name,
			v1_hl = helper.person_hl(assignee_name),
			k2 = "Reporter:",
			v2 = string.format("%s %s", user_icon, reporter_name),
			v2_hl = helper.person_hl(reporter_name),
		},
	}

	local project_key = issue.project and issue.project.key or nil
	if project_key then
		local jira_cfg = require("atlas.issues.providers.jira.api.service").jira_config()
		local project_config = jira_cfg and jira_cfg.project_config and jira_cfg.project_config[project_key] or nil
		if project_config then
			if overview_state.custom_fields_loading then
				table.insert(rows, {
					k1 = "Fields:",
					v1 = "Loading...",
					v1_hl = "AtlasTextMuted",
					k2 = "",
					v2 = "",
					v2_hl = nil,
				})
			else
				local custom_fields = overview_state.custom_fields or {}
				for _, field in ipairs(custom_fields) do
					if field.display == "table" then
						table.insert(rows, {
							k1 = string.format("%s:", field.name),
							v1 = field.formatted,
							v1_hl = field.hl_group or "Normal",
							k2 = "",
							v2 = "",
							v2_hl = nil,
						})
					end
				end
			end
		end
	end

	return rows
end

--------------------------------------------------------------------------------
-- Chips
--------------------------------------------------------------------------------

---@param issue Issue
---@return IssuesPanelChip[]
function M.chips(issue)
	local chips = {}

	local parent_key = issue.parent and issue.parent.key or nil
	table.insert(chips, {
		label = string.format("%s %s", icons.pulls("branch"), parent_key or "-"),
		hl = parent_key and "AtlasJiraChipParent" or "AtlasTextMuted",
	})

	local sp = issue.story_points
	local sp_text = type(sp) == "number" and tostring(sp) or "-"
	table.insert(chips, {
		label = string.format("%s %s", icons.issues_provider("jira", "provider"), sp_text),
		hl = type(sp) == "number" and "AtlasJiraChipStoryPoints" or "AtlasTextMuted",
	})

	local due = utils.format_date and utils.format_date(issue.duedate) or tostring(issue.duedate or "")
	local due_text = due ~= "" and due or "-"
	table.insert(chips, {
		label = string.format("%s %s", icons.general("created"), due_text),
		hl = due ~= "" and "AtlasJiraChipDueDate" or "AtlasTextMuted",
	})

	if overview_state.custom_fields_loading then
		table.insert(chips, { label = "Loading...", hl = "AtlasTextMuted" })
	else
		local custom_fields = overview_state.custom_fields or {}
		for _, field in ipairs(custom_fields) do
			if field.display == "chip" then
				table.insert(chips, {
					label = field.formatted,
					hl = field.hl_group or "AtlasChipActive",
				})
			end
		end
	end

	return chips
end

---@param raw any
---@return string|nil
function M.convert_description(raw)
	if type(raw) ~= "table" then
		return type(raw) == "string" and raw or nil
	end
	local adf = require("atlas.issues.providers.jira.converted.adf")
	return adf.to_markdown(raw)
end

---@return AtlasMarkdownCompletionProvider|nil
function M.comment_completion()
	local author = require("atlas.issues.providers.jira.completion.author")
	return author.build_completion()
end

---@param body string
---@return string
function M.resolve_comment_body(body)
	local author = require("atlas.issues.providers.jira.completion.author")
	return author.resolve(body)
end

--------------------------------------------------------------------------------
-- Fetches
--------------------------------------------------------------------------------

---@param issue Issue
---@param refresh fun()
---@param opts { force_load?: boolean }|nil
function M.fetches(issue, refresh, opts)
	local issue_key = tostring(issue.key or "")
	local project_key = issue.project and issue.project.key or nil

	local jira_cfg = require("atlas.issues.providers.jira.api.service").jira_config()
	local project_config = jira_cfg and jira_cfg.project_config and project_key and jira_cfg.project_config[project_key]
		or nil

	if not project_config then
		overview_state.custom_fields = nil
		overview_state.custom_fields_loading = false
		return
	end

	local extra_fields = {}
	for field_id, _ in pairs(project_config) do
		table.insert(extra_fields, field_id)
	end

	if #extra_fields == 0 then
		overview_state.custom_fields = nil
		overview_state.custom_fields_loading = false
		return
	end

	overview_state.custom_fields = nil
	overview_state.custom_fields_loading = true

	local issues_api = require("atlas.issues.providers.jira.api.issues")
	issues_api.get_custom_fields(issue_key, extra_fields, function(values, err)
		overview_state.custom_fields_loading = false

		if err or not values then
			overview_state.custom_fields = nil
			refresh()
			return
		end

		overview_state.custom_fields = {}
		for field_id, field_cfg in pairs(project_config) do
			local raw_value = values[field_id]
			if raw_value ~= nil then
				local format_ok, formatted = pcall(field_cfg.format, raw_value)
				if format_ok and formatted and formatted ~= "" then
					table.insert(overview_state.custom_fields, {
						name = field_cfg.name or field_id,
						formatted = formatted,
						hl_group = field_cfg.hl_group,
						display = field_cfg.display or "chip",
					})
				end
			end
		end

		refresh()
	end, { force_load = opts and opts.force_load == true })
end

---@param issue Issue
---@return boolean
function M.is_loading(issue)
	return overview_state.description_loading or comments_state.any_loading() or history_state.any_loading()
end

--------------------------------------------------------------------------------
-- History rendering
--------------------------------------------------------------------------------

local FIELD_LABELS = {
	Comment = "a comment",
	issuetype = "issue type",
	timeoriginalestimate = "original estimate",
	timeestimate = "remaining estimate",
	timespent = "time spent",
	WorklogId = "worklog",
	IssueParentAssociation = "parent issue",
}

---@param seconds string|nil
---@return string
local function format_estimate(seconds)
	if seconds == nil or seconds == "" then
		return "0m"
	end
	local n = tonumber(seconds)
	if n == nil then
		return tostring(seconds)
	end
	local h = math.floor(n / 3600)
	local m = math.floor((n % 3600) / 60)
	return h > 0 and string.format("%dh %dm", h, m) or string.format("%dm", m)
end

---@param item IssueHistoryItem
---@return { label: string, content: string|nil }
function M.format_history_item(item)
	local field = item.field or ""
	local from = item.from_string or item.from
	local to = item.to_string or item.to
	local has_from = from ~= nil and vim.trim(from) ~= ""
	local has_to = to ~= nil and vim.trim(to) ~= ""

	local action = (has_from and not has_to) and "deleted" or (not has_from and has_to) and "added" or "updated"
	local label = string.format("%s %s", action, FIELD_LABELS[field] or field)

	local content
	if field == "Comment" then
		content = nil
	elseif field == "description" then
		local f = has_from and vim.trim(from:gsub("%s+", " ")) or ""
		local t = has_to and vim.trim(to:gsub("%s+", " ")) or ""
		if #f > 200 then
			f = f:sub(1, 197) .. "..."
		end
		if #t > 200 then
			t = t:sub(1, 197) .. "..."
		end
		content = (f ~= "" and t ~= "") and string.format("%s\n\n↓\n\n%s", f, t)
			or (f ~= "" and f or (t ~= "" and t or nil))
	elseif field == "assignee" then
		content = string.format("%s -> %s", from or "Unassigned", to or "Unassigned")
	elseif field == "priority" then
		local fi = icons.issues_priority(from or "")
		local ti = icons.issues_priority(to or "")
		content = string.format("%s %s -> %s %s", fi, from or "", ti, to or "")
	elseif field == "issuetype" then
		local fi = icons.issues_type(from or "")
		local ti = icons.issues_type(to or "")
		content = string.format("%s %s -> %s %s", fi, from or "", ti, to or "")
	elseif field == "timeoriginalestimate" or field == "timeestimate" or field == "timespent" then
		content = string.format("%s -> %s", format_estimate(from), format_estimate(to))
	elseif field == "IssueParentAssociation" then
		local f = (from and vim.trim(from) ~= "") and from or "None"
		local t = (to and vim.trim(to) ~= "") and to or "None"
		content = string.format("%s -> %s", f, t)
	elseif has_from or has_to then
		content = string.format("%s -> %s", from or "", to or "")
	end

	return { label = label, content = content }
end

---@param item IssueHistoryItem
---@param row string
---@param row_index integer
---@return table[]|nil
function M.history_item_hl(item, row, row_index)
	local field = item.field or ""

	if field == "description" then
		local from = item.from_string or item.from
		if from ~= nil and vim.trim(from) ~= "" and row_index <= 1 then
			return { { start_col = 0, end_col = #row, hl_group = "AtlasTextMutedStrikethrough" } }
		end
		return nil
	end

	local arrow_fields =
		{ assignee = true, priority = true, issuetype = true, status = true, IssueParentAssociation = true }
	if arrow_fields[field] then
		local s, e = row:find(" -> ", 1, true)
		if not s then
			return nil
		end
		if field == "assignee" then
			return {
				{ start_col = 0, end_col = s - 1, hl_group = helper.person_hl(item.from_string or item.from) },
				{ start_col = e, end_col = #row, hl_group = helper.person_hl(item.to_string or item.to) },
			}
		elseif field == "priority" then
			return {
				{ start_col = 0, end_col = s - 1, hl_group = helper.priority_hl(item.from_string or item.from) },
				{ start_col = e, end_col = #row, hl_group = helper.priority_hl(item.to_string or item.to) },
			}
		elseif field == "issuetype" then
			return {
				{ start_col = 0, end_col = s - 1, hl_group = helper.issue_type_hl(item.from_string or item.from) },
				{ start_col = e, end_col = #row, hl_group = helper.issue_type_hl(item.to_string or item.to) },
			}
		elseif field == "status" then
			return {
				{ start_col = 0, end_col = s - 1, hl_group = helper.status_hl(item.from) },
				{ start_col = e, end_col = #row, hl_group = helper.status_hl(item.to) },
			}
		elseif field == "IssueParentAssociation" then
			return {
				{ start_col = 0, end_col = s - 1, hl_group = "AtlasJiraKey" },
				{ start_col = e, end_col = #row, hl_group = "AtlasJiraKey" },
			}
		end
	end
end

--------------------------------------------------------------------------------
-- Tabs
--------------------------------------------------------------------------------

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
			key = "activity",
			label = "History",
			icon = icons.pulls("activity"),
			mod = require("atlas.issues.ui.panel.issue.tabs.activity"),
		},
	}
end

return M
