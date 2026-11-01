local M = {}

local gitlab_mapper = require("atlas.providers.gitlab.mapper")
local json = require("atlas.core.json")

M.to_user = gitlab_mapper.to_user

---@param raw_assignees table[]|nil
---@return AtlasUser[]
local function assignees(raw_assignees)
	local users = {}
	for _, raw in ipairs(json.safe_table(raw_assignees)) do
		local user = M.to_user(raw)
		if user then
			table.insert(users, user)
		end
	end
	return users
end

---@param raw_labels table[]|nil
---@return IssueLabel[]
local function labels(raw_labels)
	local result = {}
	for _, raw in ipairs(json.safe_table(raw_labels)) do
		raw = json.safe_table(raw)
		local name = json.safe_str(raw.title)
		if name and name ~= "" then
			table.insert(result, {
				name = name,
				color = json.safe_str(raw.color),
			})
		end
	end
	return result
end

---@param raw any
---@return IssueMilestone|nil
local function milestone(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local title = json.safe_str(raw.title)
	if title == nil then
		return nil
	end
	local id = json.safe_str(raw.id) or ""
	return { id = tonumber(id:match("([^/]+)$")), title = title }
end

---@param state string|nil
---@return string, string
local function normalize_state(state)
	local s = tostring(state or ""):lower()
	if s == "closed" then
		return "Closed", "closed"
	end
	return "Open", "open"
end

---@param raw_type any
---@return IssueType|nil
local function to_issue_type(raw_type)
	local id = json.safe_str(raw_type)
	if id == nil or id == "" then
		return nil
	end
	id = id:lower()
	local name = id:gsub("_", " ")
	name = name:sub(1, 1):upper() .. name:sub(2)
	return { id = id, name = name, subtask = false }
end

---@param raw any Decoded API value.
---@return GitLabIssue|nil
function M.to_issue(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local iid = tonumber(raw.iid)
	if iid == nil then
		return nil
	end

	local web_url = json.safe_str(raw.web_url) or ""
	local refs = json.nilify(raw.references)
	local key = json.safe_str(raw.reference) or (type(refs) == "table" and json.safe_str(refs.full) or nil)
	local project_path = key and key:match("^(.-)#%d+$") or nil
	if not key or key == "" then
		project_path = web_url:match("^https?://[^/]+/(.+)/%-/issues/")
		key = project_path and (project_path .. "#" .. tostring(iid)) or string.format("#%d", iid)
	end

	local status_name, status_id = normalize_state(raw.state)
	local title = json.safe_str(raw.title) or ""

	local issue_assignees = assignees(json.safe_table(raw.assignees).nodes or raw.assignees)
	local created_at = json.safe_str(raw.created_at)
	local updated_at = json.safe_str(raw.updated_at)
	local closed_at = json.safe_str(raw.closed_at)

	---@type GitLabIssue
	local issue = {
		key = key,
		project_path = project_path or "",
		iid = iid,
		title = title,
		status = status_name,
		status_id = status_id,
		confidential = json.nilify(raw.confidential),
		type = to_issue_type(raw.issue_type),
		assignee = issue_assignees[1],
		reporter = M.to_user(raw.author),
		duedate = json.safe_str(raw.due_date),
		parent = nil,
		url = web_url ~= "" and web_url or nil,
		created_at = created_at,
		updated_at = updated_at,
		closed_at = closed_at,
		comment_count = tonumber(raw.user_notes_count) or 0,
		is_subscribed = json.nilify(raw.subscribed),
		node_id = json.safe_str(raw.node_id),
	}
	return issue
end

---@param work_item any GraphQL `WorkItem`, which holds an issue's award emoji
---@return table[]
local function work_item_awards(work_item)
	local widget = json.safe_table(json.safe_table(work_item).features).awardEmoji
	return json.safe_table(json.safe_table(json.safe_table(widget).awardEmoji).nodes)
end

---@param raw any Decoded API value.
---@param work_item any GraphQL `WorkItem` of the issue
---@param viewer string|nil Username of the current user
---@return IssueDetails|nil
function M.to_issue_details(raw, work_item, viewer)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end

	---@type IssueDetails
	return {
		title = json.safe_str(raw.title),
		description = json.safe_str(raw.description) or "",
		reactions = gitlab_mapper.award_reactions(work_item_awards(work_item), viewer),
		assignees = assignees(json.safe_table(raw.assignees).nodes),
		labels = labels(json.safe_table(raw.labels).nodes),
		milestone = milestone(raw.milestone),
	}
end

---@param raw_list table[]|nil
---@return Issue[]
function M.to_issues_list(raw_list)
	local out = {}
	for _, raw in ipairs(json.safe_table(raw_list)) do
		local issue = M.to_issue(raw)
		if issue ~= nil then
			table.insert(out, issue)
		end
	end
	return out
end

---@param key string
---@return string project_path, integer|nil iid
function M.parse_key(key)
	local k = tostring(key or "")
	local path, num = k:match("^(.-)#(%d+)$")
	if path and num then
		return path, tonumber(num)
	end
	return "", nil
end

---@param note any GraphQL `Note`
---@param discussion any GraphQL `Discussion` the note belongs to
---@param viewer string|nil Username of the current user
---@param author_username string|nil
---@return IssueComment|nil
function M.to_comment(note, discussion, viewer, author_username)
	note = json.safe_table(note)
	local id = gitlab_mapper.note_id(note.id)
	if not id then
		return nil
	end
	discussion = json.safe_table(discussion)
	local root = json.safe_table(json.safe_table(discussion.notes).nodes)[1]
	local root_id = gitlab_mapper.note_id(json.safe_table(root).id)
	return {
		id = id,
		author = M.to_user(note.author),
		author_roles = gitlab_mapper.author_roles(note, author_username),
		body = json.safe_str(note.body) or "",
		created_at = json.safe_str(note.createdAt) or "",
		parent_id = root_id ~= id and root_id or nil,
		thread_id = json.safe_str(discussion.id),
		reactions = gitlab_mapper.award_reactions(json.safe_table(note.awardEmoji).nodes, viewer),
	}
end

---@param raw any GraphQL `Issue`
---@param work_item any GraphQL `WorkItem` of the issue
---@param viewer string|nil Username of the current user
---@param author_username string|nil
---@return IssueComment|nil
function M.to_description(raw, work_item, viewer, author_username)
	raw = json.safe_table(raw)
	local id = json.safe_str(raw.id)
	if not id then
		return nil
	end
	return {
		id = id,
		url = json.safe_str(raw.webUrl),
		author = M.to_user(raw.author),
		author_roles = gitlab_mapper.author_roles(raw, author_username),
		body = json.safe_str(raw.description) or "",
		created_at = json.safe_str(raw.createdAt) or "",
		reactions = gitlab_mapper.award_reactions(work_item_awards(work_item), viewer),
	}
end

---@param raw any Decoded API value.
---@return IssueActivityEntry|nil
function M.to_activity_from_note(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" or json.nilify(raw.id) == nil then
		return nil
	end
	local body = json.safe_str(raw.body) or ""
	if body == "" then
		return nil
	end
	return {
		kind = "other",
		actor = M.to_user(raw.author),
		date = json.safe_str(raw.createdAt),
		label = body,
	}
end

return M
