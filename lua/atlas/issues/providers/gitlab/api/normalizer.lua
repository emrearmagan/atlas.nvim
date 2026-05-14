local M = {}

---@param value any
---@return any
local function nilify(value)
	if value == nil or value == vim.NIL then
		return nil
	end
	return value
end

---@param value any
---@return string|nil
local function safe_str(value)
	value = nilify(value)
	if value == nil then
		return nil
	end
	return tostring(value)
end

---@param value any
---@return table
local function safe_table(value)
	value = nilify(value)
	if type(value) ~= "table" then
		return {}
	end
	return value
end

---@param raw_user table|nil
---@return IssueUser|nil
function M.normalize_user(raw_user)
	raw_user = nilify(raw_user)
	if type(raw_user) ~= "table" then
		return nil
	end
	local username = safe_str(raw_user.username) or ""
	if username == "" then
		return nil
	end
	return {
		account_id = username,
		display_name = safe_str(raw_user.name) or username,
		email = safe_str(raw_user.public_email) or "",
	}
end

---@param raw_assignees table[]|nil
---@return IssueUser|nil
local function first_assignee(raw_assignees)
	for _, raw in ipairs(safe_table(raw_assignees)) do
		local user = M.normalize_user(raw)
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
function M.normalize_issue(raw)
	raw = nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local iid = tonumber(raw.iid)
	if iid == nil then
		return nil
	end

	local web_url = safe_str(raw.web_url) or ""
	local refs = nilify(raw.references)
	local key = type(refs) == "table" and safe_str(refs.full) or nil
	if not key or key == "" then
		local extracted = web_url:match("^https?://[^/]+/(.+)/%-/issues/")
		key = extracted and (extracted .. "#" .. tostring(iid)) or string.format("#%d", iid)
	end

	local status_name, status_id = normalize_state(raw.state)
	local title = safe_str(raw.title) or ""
	local description = safe_str(raw.description) or ""

	local labels_raw = safe_table(raw.labels) -- list of label-name strings
	local labels = {}
	for _, name in ipairs(labels_raw) do
		if type(name) == "string" and name ~= "" then
			table.insert(labels, { name = name })
		end
	end

	local assignees = safe_table(raw.assignees)
	local milestone = nilify(raw.milestone)

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
		reporter = M.normalize_user(raw.author),
		story_points = tonumber(nilify(raw.weight)),
		duedate = safe_str(raw.due_date),
		parent = nil,
		url = web_url ~= "" and web_url or nil,
		is_subscribed = type(raw.subscribed) == "boolean" and raw.subscribed or nil,
		_raw = {
			iid = iid,
			project_id = tonumber(raw.project_id),
			project_path = project_path,
			description = description,
			created_at = safe_str(raw.created_at) or "",
			updated_at = safe_str(raw.updated_at) or "",
			closed_at = safe_str(raw.closed_at),
			labels = labels,
			label_names = labels_raw,
			assignees = assignees,
			milestone = milestone,
			comment_count = tonumber(raw.user_notes_count) or 0,
			web_url = web_url,
			confidential = raw.confidential == true,
			issue_type = safe_str(raw.issue_type),
		},
	}
	return issue
end

---@param raw_list table[]|nil
---@return Issue[]
function M.normalize_issues(raw_list)
	local out = {}
	for _, raw in ipairs(raw_list or {}) do
		local issue = M.normalize_issue(raw)
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

return M
