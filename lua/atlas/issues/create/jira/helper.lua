local M = {}

local icons = require("atlas.ui.shared.icons")
local helper = require("atlas.issues.ui.main.helper")

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
		return icons.general("user") .. " " .. fields.assignee.display_name, helper.person_hl(fields.assignee.display_name)
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

---@param fields IssueEditorFields
---@param assignees IssueUser[]|"loading"|nil
---@param issue_types IssueType[]|"loading"|nil
---@param spinner_instance SpinnerInstance|nil
---@return EditorPopupMetaRow[]
function M.meta_rows(fields, assignees, issue_types, spinner_instance)
	local user_icon, user_icon_hl = icons.general("user")
	local provider_icon, provider_hl = icons.issues_provider("jira", "provider")
	local assignee_text, assignee_hl = get_assignee_display(fields, assignees, spinner_instance)
	local issue_type_text, issue_type_hl = get_issue_type_display(fields, issue_types, spinner_instance)
	local reporter_name = fields.reporter and fields.reporter.display_name or "Unknown"
	local project_name = fields.project or "Unknown"

	return {
		{
			"Assignee:",
			{ text = assignee_text, hl = assignee_hl },
			"Reporter:",
			{
				text = string.format("%s %s", user_icon, reporter_name),
				spans = {
					{ start_col = 0, end_col = #user_icon, hl_group = user_icon_hl },
					{
						start_col = #user_icon + 1,
						end_col = #user_icon + 1 + #reporter_name,
						hl_group = helper.person_hl(reporter_name),
					},
				},
			},
		},
		{
			"Project:",
			{
				text = string.format("%s %s", provider_icon, project_name),
				spans = {
					{ start_col = 0, end_col = #provider_icon, hl_group = provider_hl },
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
