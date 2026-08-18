local M = {}

local json = require("atlas.core.json")

---@param raw table
---@return ShortcutIssueUser
function M.to_user(raw)
	local profile = json.safe_table(raw.profile)
	local id = tostring(raw.id)
	local mention_name = json.safe_str(profile.mention_name) or json.safe_str(raw.mention_name)
	local display_name = json.safe_str(profile.name) or json.safe_str(raw.name) or mention_name or id
	return { account_id = id, display_name = display_name, mention_name = mention_name }
end

---@param users IssueUser[]
---@param id string|nil
---@return IssueUser|nil
local function user_for(users, id)
	if id == nil then
		return nil
	end
	for _, user in ipairs(users) do
		if user.account_id == id then
			return user
		end
	end
	return nil
end

---@param raw_labels table[]
---@return IssueLabel[]
local function labels(raw_labels)
	local result = {}
	for _, label in ipairs(raw_labels) do
		table.insert(result, {
			name = tostring(label.name),
			color = json.safe_str(label.color),
		})
	end
	return result
end

---@param users IssueUser[]
---@param owner_ids string[]
---@return IssueUser[]
local function owners(users, owner_ids)
	local result = {}
	for _, id in ipairs(owner_ids) do
		local owner = user_for(users, id)
		if owner then
			table.insert(result, owner)
		end
	end
	return result
end

---@param raw table
---@return string, string
local function story_status(raw)
	if raw.archived then
		return "Archived", "archived"
	end
	if raw.completed then
		return "Completed", "completed"
	end
	if raw.started then
		return "Started", "started"
	end
	return "Not Started", "not_started"
end

---@param id integer
---@return IssueRef
local function shallow_story(id)
	return { key = tostring(id) }
end

---@param raw table
---@param users IssueUser[]
---@return ShortcutIssue
function M.to_issue(raw, users)
	local parent_id = tonumber(json.nilify(raw.parent_story_id))
	local owner_ids = raw.owner_ids or {}
	local mapped_labels = labels(raw.labels or {})
	local comments = raw.comment_ids or raw.comments
	local story_type = tostring(raw.story_type)
	local status, status_id = story_status(raw)

	---@type ShortcutIssue
	local issue = {
		id = raw.id,
		key = tostring(raw.id),
		title = tostring(raw.name),
		status = status,
		status_id = status_id,
		type = {
			id = story_type,
			name = story_type,
			subtask = parent_id ~= nil,
		},
		assignee = owners(users, owner_ids)[1],
		reporter = user_for(users, raw.requested_by_id),
		story_points = tonumber(json.nilify(raw.estimate)),
		duedate = json.safe_str(raw.deadline),
		url = json.safe_str(raw.app_url),
		created_at = json.safe_str(raw.created_at),
		updated_at = json.safe_str(raw.updated_at),
		closed_at = json.safe_str(raw.completed_at),
		comment_count = comments and #comments or nil,
		owner_count = #owner_ids,
		labels = mapped_labels,
	}
	return issue
end

---@param raw table
---@param users IssueUser[]
---@return ShortcutIssueDetails
function M.to_issue_details(raw, users)
	local parent_id = tonumber(json.nilify(raw.parent_story_id))
	---@type ShortcutIssueDetails
	local details = {
		description = json.safe_str(raw.description) or "",
		assignees = owners(users, raw.owner_ids or {}),
		labels = labels(raw.labels or {}),
		milestone = nil,
		parent = parent_id and shallow_story(parent_id) or nil,
		sub_issues = {},
	}
	for _, id in ipairs(raw.sub_task_story_ids or {}) do
		table.insert(details.sub_issues, shallow_story(id))
	end
	return details
end

---@param stories table[]
---@param users IssueUser[]
---@return ShortcutIssue[]
function M.to_issues(stories, users)
	local result = {}
	for _, story in ipairs(stories) do
		table.insert(result, M.to_issue(story, users))
	end
	return result
end

---@param raw table
---@param users? IssueUser[]
---@return IssueComment
function M.to_comment(raw, users)
	return {
		id = tostring(raw.id),
		url = json.safe_str(raw.app_url),
		author = user_for(users or {}, json.safe_str(raw.author_id)),
		body = json.safe_str(raw.text),
		created = json.safe_str(raw.created_at),
		updated = json.safe_str(raw.updated_at),
		parent_id = tonumber(json.nilify(raw.parent_id)),
		deleted = raw.deleted == true,
	}
end

local ACTION_LABELS = {
	create = "created",
	update = "updated",
	delete = "deleted",
	merge = "merged",
	push = "pushed",
	close = "closed",
	open = "opened",
	reopen = "reopened",
	sync = "synced",
	comment = "commented on",
	["bulk-update"] = "bulk updated",
}

local CHANGE_LABELS = {
	workflow_state_id = "status",
	owner_ids = "owners",
	label_ids = "labels",
	name = "name",
	description = "description",
	story_type = "type",
	estimate = "points",
	deadline = "deadline",
	parent_story_id = "parent",
	requested_by_id = "requester",
	epic_id = "epic",
	iteration_id = "iteration",
	group_id = "team",
	project_id = "project",
	complete = "completion",
	completed = "completion",
	archived = "archived",
	verb = "relationship",
}

---@param value string
---@return string
local function entity_label(value)
	return value:gsub("^story%-", ""):gsub("[_-]", " ")
end

---@param action table
---@return string|nil
local function action_body(action)
	local fields = {}
	for field in pairs(json.safe_table(action.changes)) do
		if CHANGE_LABELS[field] then
			table.insert(fields, CHANGE_LABELS[field])
		end
	end
	if #fields > 0 then
		table.sort(fields)
		return table.concat(fields, ", ")
	end
	if action.entity_type == "pull-request" then
		return string.format("#%s %s", tostring(action.number), tostring(action.title))
	end
	if action.entity_type == "story-link" then
		return string.format(
			"#%s %s #%s",
			tostring(action.subject_id),
			tostring(action.verb),
			tostring(action.object_id)
		)
	end
	return json.safe_str(action.name) or json.safe_str(action.title) or json.safe_str(action.description)
end

---@param raw table
---@return IssueActivityEntry[]
function M.to_activity(raw)
	local actor_name = json.safe_str(raw.actor_name)
	if actor_name == nil or actor_name == "" then
		actor_name = raw.automation_id and "Automation" or "Unknown"
	end
	local actor = {
		account_id = json.safe_str(raw.member_id),
		display_name = actor_name,
	}
	local entries = {}
	for _, action in ipairs(json.safe_table(raw.actions)) do
		local entity = entity_label(tostring(action.entity_type or "activity"))
		local verb = ACTION_LABELS[tostring(action.action)] or tostring(action.action or "updated")
		local label = entity == "comment" and verb == "created" and "commented" or (verb .. " " .. entity)
		table.insert(entries, {
			kind = tostring(action.entity_type or "history"),
			actor = actor,
			date = json.safe_str(raw.changed_at),
			label = label,
			body = action_body(action),
		})
	end
	return entries
end

---@param history table[]
---@return IssueActivityEntry[]
function M.to_history(history)
	local entries = {}
	for _, raw in ipairs(history) do
		for _, entry in ipairs(M.to_activity(raw)) do
			table.insert(entries, entry)
		end
	end
	return entries
end

return M
