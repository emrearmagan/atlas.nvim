local M = {}

local icons = require("atlas.ui.shared.icons")
local helper = require("atlas.issues.ui.presentation")

---@param fields IssueEditorFields
---@param assignees IssueUser[]|"loading"|nil
---@param spinner_instance SpinnerInstance|nil
---@return string
---@return string
local function get_assignee_display(fields, assignees, spinner_instance)
	if assignees == "loading" then
		local frame = spinner_instance and spinner_instance:current_frame() or "⠋"
		return frame .. " Loading...", "AtlasTextMuted"
	end

	if fields.assignee then
		return icons.general("user") .. " " .. fields.assignee.display_name,
			helper.person_hl(fields.assignee.display_name)
	end

	return icons.general("user") .. " Unassigned", helper.person_hl(nil)
end

---@param fields IssueEditorFields
---@param issue_types IssueType[]|"loading"|nil
---@param spinner_instance SpinnerInstance|nil
---@return string
---@return string
local function get_issue_type_display(fields, issue_types, spinner_instance)
	if issue_types == "loading" then
		local frame = spinner_instance and spinner_instance:current_frame() or "⠋"
		return frame .. " Loading...", "AtlasTextMuted"
	end

	local name = fields.issue_type and tostring(fields.issue_type.name or "") or ""
	if name ~= "" then
		local icon, icon_hl = icons.issues_type(name)
		return string.format("%s %s", icon, name), icon_hl
	end

	local _, icon_hl = icons.issues_type(nil)
	return "None", icon_hl
end

---@param reporter IssueUser|nil
---@param loading boolean
---@param spinner_instance SpinnerInstance|nil
---@return string
---@return string
local function get_reporter_display(reporter, loading, spinner_instance)
	if loading then
		local frame = spinner_instance and spinner_instance:current_frame() or "⠋"
		return frame .. " Loading...", "AtlasTextMuted"
	end

	local name = reporter and reporter.display_name or "Unknown"
	return icons.general("user") .. " " .. name, helper.person_hl(name)
end

---@param fields IssueEditorFields
---@param assignees IssueUser[]|"loading"|nil
---@param issue_types IssueType[]|"loading"|nil
---@param reporter IssueUser|nil
---@param reporter_loading boolean
---@param spinner_instance SpinnerInstance|nil
---@return AtlasFormMetaRow[]
function M.meta_rows(fields, assignees, issue_types, reporter, reporter_loading, spinner_instance)
	local provider_icon = icons.issues_provider("jira", "provider")
	local assignee_text, assignee_hl = get_assignee_display(fields, assignees, spinner_instance)
	local issue_type_text, issue_type_hl = get_issue_type_display(fields, issue_types, spinner_instance)
	local reporter_text, reporter_hl = get_reporter_display(reporter, reporter_loading, spinner_instance)
	local project_name = fields.project or "Unknown"

	return {
		{
			"Assignee:",
			{ text = assignee_text, hl = assignee_hl },
			"Reporter:",
			{ text = reporter_text, hl = reporter_hl },
		},
		{
			"Project:",
			{
				text = string.format("%s %s", provider_icon, project_name),
				spans = {
					{ start_col = 0, end_col = #provider_icon, hl_group = "AtlasJiraKey" },
					{
						start_col = #provider_icon + 1,
						end_col = #provider_icon + 1 + #project_name,
						hl_group = "AtlasProjectKey",
					},
				},
			},
			"Type:",
			{ text = issue_type_text, hl = issue_type_hl },
		},
	}
end

return M
