local M = {}

local json = require("atlas.core.json")
local service = require("atlas.pulls.providers.azure.api.service")

---@param raw table|nil
---@return IssueUser|nil
function M.to_user(raw)
	raw = json.nilify(raw)
	if not raw then
		return nil
	end
	return {
		account_id = raw.id,
		display_name = raw.displayName,
		username = raw.uniqueName,
	}
end

---@param raw table
---@return AzureIssue
function M.to_issue(raw)
	local fields = raw.fields
	local project = fields["System.TeamProject"]
	local item_type = fields["System.WorkItemType"]
	local parent = fields["System.Parent"]
	return {
		key = tostring(raw.id),
		id = raw.id,
		project = project,
		title = fields["System.Title"],
		status = fields["System.State"],
		status_id = fields["System.State"],
		type = { id = item_type, name = item_type, subtask = parent ~= nil },
		assignee = M.to_user(fields["System.AssignedTo"]),
		reporter = M.to_user(fields["System.CreatedBy"]),
		story_points = fields["Microsoft.VSTS.Scheduling.StoryPoints"],
		duedate = fields["Microsoft.VSTS.Scheduling.DueDate"],
		parent = parent and { key = tostring(parent) } or nil,
		url = string.format("%s/%s/_workitems/edit/%d", service.base_url(), service.url_encode(project), raw.id),
		created_at = fields["System.CreatedDate"],
		updated_at = fields["System.ChangedDate"],
		closed_at = fields["Microsoft.VSTS.Common.ClosedDate"],
		comment_count = fields["System.CommentCount"],
		description_format = json.safe_table(raw.multilineFieldsFormat)["System.Description"] or "html",
	}
end

---@param raw table
---@return AzureIssueDetails
function M.to_issue_details(raw)
	local fields = raw.fields
	local assigned = M.to_user(fields["System.AssignedTo"])
	local labels = {}
	for name in tostring(fields["System.Tags"] or ""):gmatch("[^;]+") do
		table.insert(labels, { name = vim.trim(name) })
	end
	return {
		description = fields["System.Description"] or "",
		description_format = json.safe_table(raw.multilineFieldsFormat)["System.Description"] or "html",
		assignees = assigned and { assigned } or {},
		labels = labels,
	}
end

return M
