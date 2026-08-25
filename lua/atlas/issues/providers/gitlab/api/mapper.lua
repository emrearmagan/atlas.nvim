local M = {}

local json = require("atlas.core.json")

---@param raw_user any Decoded API value.
---@return IssueUser|nil
function M.to_user(raw_user)
	raw_user = json.nilify(raw_user)
	if type(raw_user) ~= "table" then
		return nil
	end
	local username = json.safe_str(raw_user.username) or ""
	if username == "" then
		return nil
	end
	local name = json.safe_str(raw_user.name) or ""
	return {
		account_id = username,
		display_name = name ~= "" and name or username,
	}
end

---@param raw_assignees table[]|nil
---@return IssueUser[]
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
		local name = type(raw) == "string" and raw or json.safe_str(raw.name) or json.safe_str(raw.title)
		if name and name ~= "" then
			table.insert(result, {
				name = name,
				color = type(raw) == "table" and json.safe_str(raw.color) or nil,
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
	return { title = title }
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
	local key = type(refs) == "table" and json.safe_str(refs.full) or nil
	local project_path = key and key:match("^(.-)#%d+$") or nil
	if not key or key == "" then
		project_path = web_url:match("^https?://[^/]+/(.+)/%-/issues/")
		key = project_path and (project_path .. "#" .. tostring(iid)) or string.format("#%d", iid)
	end

	local status_name, status_id = normalize_state(raw.state)
	local title = json.safe_str(raw.title) or ""

	local issue_assignees = assignees(raw.assignees)
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
		type = to_issue_type(raw.issue_type),
		assignee = issue_assignees[1],
		reporter = M.to_user(raw.author),
		story_points = tonumber(json.nilify(raw.weight)),
		duedate = json.safe_str(raw.due_date),
		parent = nil,
		url = web_url ~= "" and web_url or nil,
		created_at = created_at,
		updated_at = updated_at,
		closed_at = closed_at,
		comment_count = tonumber(raw.user_notes_count) or 0,
		is_subscribed = json.nilify(raw.subscribed),
	}
	return issue
end

---@param raw any Decoded API value.
---@return IssueDetails|nil
function M.to_issue_details(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end

	---@type IssueDetails
	return {
		description = json.safe_str(raw.description) or "",
		assignees = assignees(json.safe_table(raw.assignees).nodes or raw.assignees),
		labels = labels(json.safe_table(raw.labels).nodes or raw.labels),
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

---@param raw any   GraphQL note id like "gid://gitlab/Note/123" or a plain int from REST
---@return string
local function note_id_tail(raw)
	local s = tostring(raw or "")
	return s:match("([^/]+)$") or s
end

---@param raw table
---@return table<string, integer>|nil
local function reaction_counts(raw)
	local award_emoji = json.safe_table(raw.awardEmoji)
	local values = type(award_emoji.nodes) == "table" and award_emoji.nodes or raw.award_emoji
	local reactions
	for _, reaction in ipairs(json.safe_table(values)) do
		local name = type(reaction) == "table" and json.safe_str(reaction.name) or nil
		if name and name ~= "" then
			reactions = reactions or {}
			reactions[name] = (reactions[name] or 0) + 1
		end
	end
	return reactions
end

---@param raw any Decoded API value.
---@param first_id any|nil           -- id of the root note in this discussion; nil when raw is the root
---@param discussion_id string|nil
---@return IssueComment|nil
function M.to_comment_from_note(raw, first_id, discussion_id)
	raw = json.nilify(raw)
	if type(raw) ~= "table" or json.nilify(raw.id) == nil then
		return nil
	end
	local id = note_id_tail(raw.id)
	local parent_id = nil
	if first_id ~= nil and tostring(first_id) ~= id then
		parent_id = tostring(first_id)
	end
	return {
		id = id,
		self = nil,
		url = nil,
		author = M.to_user(raw.author),
		body = json.safe_str(raw.body) or "",
		created = json.safe_str(raw.createdAt) or json.safe_str(raw.created_at) or "",
		updated = json.safe_str(raw.updatedAt) or json.safe_str(raw.updated_at),
		parent_id = parent_id,
		children = nil,
		reactions = reaction_counts(raw),
		_raw = discussion_id and { discussion_id = discussion_id } or nil,
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
		kind = "system",
		actor = M.to_user(raw.author),
		date = json.safe_str(raw.createdAt) or json.safe_str(raw.created_at),
		label = body,
	}
end

return M
