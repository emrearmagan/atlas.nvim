local M = {}

local json = require("atlas.core.json")

---@param raw_user table|nil
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
	return {
		account_id = username,
		display_name = json.safe_str(raw_user.name) or username,
	}
end

---@param raw_assignees table[]|nil
---@return IssueUser|nil
local function first_assignee(raw_assignees)
	for _, raw in ipairs(json.safe_table(raw_assignees)) do
		local user = M.to_user(raw)
		if user then
			return user
		end
	end
	return nil
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

---@param raw table
---@return Issue|nil
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
	if not key or key == "" then
		local extracted = web_url:match("^https?://[^/]+/(.+)/%-/issues/")
		key = extracted and (extracted .. "#" .. tostring(iid)) or string.format("#%d", iid)
	end

	local status_name, status_id = normalize_state(raw.state)
	local title = json.safe_str(raw.title) or ""
	local description = json.safe_str(raw.description) or ""

	local labels_raw = json.safe_table(raw.labels) -- list of label-name strings
	local labels = {}
	for _, name in ipairs(labels_raw) do
		if type(name) == "string" and name ~= "" then
			table.insert(labels, { name = name })
		end
	end

	local assignees = json.safe_table(raw.assignees)
	local milestone = json.nilify(raw.milestone)

	local project_path = key:match("^(.-)#") or ""

	---@type Issue
	local issue = {
		key = key,
		summary = title,
		project = nil,
		status = status_name,
		status_id = status_id,
		status_category = nil,
		status_color = nil,
		type = nil,
		priority = nil,
		assignee = first_assignee(assignees),
		reporter = M.to_user(raw.author),
		story_points = tonumber(json.nilify(raw.weight)),
		duedate = json.safe_str(raw.due_date),
		parent = nil,
		url = web_url ~= "" and web_url or nil,
		is_subscribed = type(raw.subscribed) == "boolean" and raw.subscribed or nil,
		_raw = {
			iid = iid,
			project_id = tonumber(raw.project_id),
			project_path = project_path,
			description = description,
			created_at = json.safe_str(raw.created_at) or "",
			updated_at = json.safe_str(raw.updated_at) or "",
			closed_at = json.safe_str(raw.closed_at),
			labels = labels,
			label_names = labels_raw,
			assignees = assignees,
			milestone = milestone,
			comment_count = tonumber(raw.user_notes_count) or 0,
			web_url = web_url,
			confidential = raw.confidential == true,
			issue_type = json.safe_str(raw.issue_type),
		},
	}
	return issue
end

---@param raw_list table[]|nil
---@return Issue[]
function M.to_issues_list(raw_list)
	local out = {}
	for _, raw in ipairs(raw_list or {}) do
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

---@param raw table
---@param first_id any|nil           -- id of the root note in this discussion; nil when raw is the root
---@param discussion_id string|nil
---@return IssueComment|nil
function M.to_comment_from_note(raw, first_id, discussion_id)
	raw = json.nilify(raw)
	if type(raw) ~= "table" or json.nilify(raw.id) == nil then
		return nil
	end
	local id = tostring(raw.id)
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
		_body = nil,
		created = json.safe_str(raw.created_at) or "",
		updated = json.safe_str(raw.updated_at),
		parent_id = parent_id,
		children = nil,
		reactions = nil,
		_raw = discussion_id and { discussion_id = discussion_id } or nil,
	}
end

---@param raw table
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
		date = json.safe_str(raw.created_at),
		label = body,
	}
end

return M
