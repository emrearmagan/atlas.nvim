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

local HISTORY_FIELDS = {
	{ "System.Title", "title" },
	{ "System.State", "state" },
	{ "System.AssignedTo", "assignee" },
	{ "System.WorkItemType", "work item type" },
	{ "System.Tags", "tags" },
	{ "System.Description", "description" },
	{ "System.AreaPath", "area" },
	{ "System.IterationPath", "iteration" },
	{ "Microsoft.VSTS.Common.Priority", "priority" },
	{ "Microsoft.VSTS.Common.Severity", "severity" },
	{ "Microsoft.VSTS.Scheduling.StoryPoints", "story points" },
	{ "Microsoft.VSTS.Scheduling.Effort", "effort" },
	{ "Microsoft.VSTS.Scheduling.OriginalEstimate", "original estimate" },
	{ "Microsoft.VSTS.Scheduling.RemainingWork", "remaining work" },
	{ "Microsoft.VSTS.Scheduling.CompletedWork", "completed work" },
	{ "Microsoft.VSTS.Scheduling.DueDate", "due date" },
}

---@param field string
---@param value any
---@return string|nil
local function history_value(field, value)
	value = json.nilify(value)
	if value == nil then
		return nil
	end
	if field == "System.AssignedTo" then
		return value.displayName
	end
	return tostring(value)
end

---@param updates table[]
---@return IssueActivityEntry[]
function M.to_history(updates)
	local entries = {}
	for _, raw in ipairs(updates) do
		local fields = raw.fields or {}
		local actor = M.to_user(raw.revisedBy)
		local date = fields["System.ChangedDate"] and fields["System.ChangedDate"].newValue
		if raw.id == 1 then
			table.insert(entries, { kind = "created", actor = actor, date = date, label = "created the work item" })
		else
			for _, field in ipairs(HISTORY_FIELDS) do
				local change = fields[field[1]]
				if change then
					local from = history_value(field[1], change.oldValue)
					local to = history_value(field[1], change.newValue)
					local empty = field[1] == "System.AssignedTo" and "Unassigned" or "None"
					if from ~= to then
						table.insert(entries, {
							kind = field[1],
							actor = actor,
							date = date,
							label = "updated " .. field[2],
							body = field[1] ~= "System.Description"
									and string.format("%s -> %s", from or empty, to or empty)
								or nil,
						})
					end
				end
			end
		end
	end
	return entries
end

return M
