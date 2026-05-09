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
		return string.format("%s %s", icons.issues_type(name), name), helper.issue_type_hl(name)
	end

	return "None", helper.issue_type_hl(nil)
end

---@param fields IssueEditorFields
---@param assignees IssueUser[]|"loading"|nil
---@param issue_types IssueType[]|"loading"|nil
---@param spinner_instance SpinnerInstance|nil
---@return EditorPopupMetaRow[]
function M.meta_rows(fields, assignees, issue_types, spinner_instance)
	local user_icon = icons.general("user")
	local assignee_text, assignee_hl = get_assignee_display(fields, assignees, spinner_instance)
	local issue_type_text, issue_type_hl = get_issue_type_display(fields, issue_types, spinner_instance)
	local reporter_name = fields.reporter and fields.reporter.display_name or "Unknown"
	local project_name = fields.project or "Unknown"

	return {
		{
			"Assignee:",
			{ text = assignee_text, hl = assignee_hl },
			"Reporter:",
			{ text = string.format("%s %s", user_icon, reporter_name), hl = helper.person_hl(reporter_name) },
		},
		{
			"Project:",
			{ text = string.format("%s %s", icons.issues_provider("jira", "provider"), project_name), hl = "AtlasProjectKey" },
			"Type:",
			{ text = issue_type_text, hl = issue_type_hl },
		},
	}
end

return M
