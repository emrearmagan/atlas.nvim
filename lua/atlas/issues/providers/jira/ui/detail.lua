---@type IssuesProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.issues.ui.dashboard.helper")
local spinner = require("atlas.ui.components.spinner")

local state = {
	custom_fields = nil, ---@type table[]|nil
}

-- Header rows

---@param issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesDetailHeaderRow[]
function M.header_rows(issue, details, loading)
	local data = details or issue
	local user_icon = icons.general("user")
	local priority = tostring(data.priority or "-")
	local priority_icon, priority_hl = icons.issues_priority(priority)
	local priority_text = priority_icon ~= "" and string.format("%s %s", priority_icon, priority) or priority
	local assignee_name = type(data.assignee) == "table" and tostring(data.assignee.display_name or "") or ""
	local reporter_name = type(data.reporter) == "table" and tostring(data.reporter.display_name or "") or ""

	if assignee_name == "" then
		assignee_name = "Unassigned"
	end
	if reporter_name == "" then
		reporter_name = "Unknown"
	end

	local rows = {
		{
			k1 = "Status:",
			v1 = tostring(data.status or "Unknown"),
			v1_hl = helper.status_hl(data.status_id),
			k2 = "Priority:",
			v2 = priority_text,
			v2_hl = priority_hl,
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

	if loading then
		table.insert(rows, {
			k1 = "Fields:",
			v1 = spinner.with_text("Loading..."),
			v1_hl = "AtlasTextMuted",
			k2 = "",
			v2 = "",
			v2_hl = nil,
		})
	elseif details then
		for _, field in ipairs(state.custom_fields or {}) do
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

	return rows
end

-- Chips

---@param issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesDetailChip[]
function M.chips(issue, details, loading)
	local data = details or issue
	local chips = {}

	local parent_key = data.parent and data.parent.key or nil
	table.insert(chips, {
		label = string.format("%s %s", icons.pulls("branch"), parent_key or "-"),
		hl = parent_key and "AtlasJiraChipParent" or "AtlasTextMuted",
	})

	local sp = data.story_points
	local sp_text = type(sp) == "number" and tostring(sp) or "-"
	table.insert(chips, {
		label = string.format("%s %s", icons.issues_provider("jira", "provider"), sp_text),
		hl = type(sp) == "number" and "AtlasJiraChipStoryPoints" or "AtlasTextMuted",
	})

	local due = utils.format_date and utils.format_date(data.duedate) or tostring(data.duedate or "")
	local due_text = due ~= "" and due or "-"
	table.insert(chips, {
		label = string.format("%s %s", icons.general("created"), due_text),
		hl = due ~= "" and "AtlasJiraChipDueDate" or "AtlasTextMuted",
	})

	if loading then
		table.insert(chips, { label = spinner.with_text("Loading..."), hl = "AtlasTextMuted" })
	elseif details then
		for _, field in ipairs(state.custom_fields or {}) do
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

-- Fetches

---@param _issue Issue
---@param details IssueDetails
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun()
---@return { cancel: fun() }|nil
function M.fetch_header(_issue, details, opts, on_done)
	local function finish(custom_fields)
		state.custom_fields = custom_fields
		on_done()
	end

	local issue_key = tostring(details.key or "")
	local project_key = details.project and details.project.key or nil

	local jira_cfg = require("atlas.issues.providers.jira.api.config").jira_config()
	local project_config = jira_cfg and jira_cfg.project_config and project_key and jira_cfg.project_config[project_key]
		or nil

	if not project_config then
		finish({})
		return
	end

	local extra_fields = {}
	for field_id, _ in pairs(project_config) do
		table.insert(extra_fields, field_id)
	end

	if #extra_fields == 0 then
		finish({})
		return
	end

	local issues_api = require("atlas.issues.providers.jira.api.issues")
	return issues_api.get_custom_fields(issue_key, extra_fields, function(values, err)
		if err or not values then
			finish({})
			return
		end

		local custom_fields = {}
		for field_id, field_cfg in pairs(project_config) do
			local raw_value = values[field_id]
			if raw_value ~= nil then
				local format_ok, formatted = pcall(field_cfg.format, raw_value)
				if format_ok and formatted and formatted ~= "" then
					table.insert(custom_fields, {
						name = field_cfg.name or field_id,
						formatted = formatted,
						hl_group = field_cfg.hl_group,
						display = field_cfg.display or "chip",
					})
				end
			end
		end

		finish(custom_fields)
	end, { force_load = opts and opts.force_refresh == true })
end

-- Tabs

---@return IssuesDetailTab[]
function M.tabs()
	local overview_icon, overview_hl = icons.general("overview")
	local conversation_icon, conversation_hl = icons.general("conversation")
	local activity_icon, activity_hl = icons.pulls("activity")
	return {
		{
			key = "overview",
			label = "Overview",
			icon = overview_icon,
			icon_hl = overview_hl,
			mod = require("atlas.issues.providers.jira.ui.overview"),
		},
		{
			key = "conversation",
			label = "Conversation",
			icon = conversation_icon,
			icon_hl = conversation_hl,
			mod = require("atlas.issues.ui.detail.tabs.conversation"),
		},
		{
			key = "activity",
			label = "History",
			icon = activity_icon,
			icon_hl = activity_hl,
			mod = require("atlas.issues.ui.detail.tabs.activity"),
		},
	}
end

return M
