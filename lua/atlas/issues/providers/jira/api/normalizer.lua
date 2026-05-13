local M = {}
local adf = require("atlas.issues.providers.jira.converted.adf")

---@param raw_project table|nil
---@return IssueProject|nil
function M.normalize_project(raw_project)
	if type(raw_project) ~= "table" then
		return nil
	end

	local id = raw_project.id and tostring(raw_project.id) or ""
	local key = raw_project.key and tostring(raw_project.key) or ""
	local name = raw_project.name and tostring(raw_project.name) or ""
	local self = raw_project.self and tostring(raw_project.self) or ""
	if id == "" or key == "" or name == "" or self == "" then
		return nil
	end

	local raw_category = raw_project.projectCategory
	local category = nil
	if type(raw_category) == "table" then
		local category_id = raw_category.id and tostring(raw_category.id) or ""
		local category_name = raw_category.name and tostring(raw_category.name) or ""
		if category_id ~= "" and category_name ~= "" then
			category = {
				id = category_id,
				name = category_name,
				self = raw_category.self and tostring(raw_category.self) or nil,
				description = raw_category.description and tostring(raw_category.description) or nil,
			}
		end
	end

	return {
		id = id,
		key = key,
		name = name,
		self = self,
		category = category,
	}
end

---@param raw_type table|nil
---@return IssueType|nil
function M.normalize_issue_type(raw_type)
	if type(raw_type) ~= "table" then
		return nil
	end

	local id = raw_type.id and tostring(raw_type.id) or ""
	local name = raw_type.name and tostring(raw_type.name) or ""
	if id == "" or name == "" then
		return nil
	end

	return {
		id = id,
		name = name,
		description = raw_type.description and tostring(raw_type.description) or nil,
		subtask = raw_type.subtask == true,
	}
end

---@param value any
---@return boolean
local function is_valid(value)
	return value ~= nil and type(value) ~= "userdata"
end

---@param obj table|nil
---@param key string
---@param subkey string|nil
---@return any
local function safe_get(obj, key, subkey)
	if not is_valid(obj) then
		return nil
	end
	local val = obj[key]
	if subkey then
		if not is_valid(val) then
			return nil
		end
		return val[subkey]
	end
	return val
end

---@param value any
---@return string|nil
local function to_string_or_nil(value)
	if not is_valid(value) then
		return nil
	end
	return tostring(value)
end

---@param raw_status table|nil
---@return string|nil, string|nil, string|nil, string|nil
local function extract_status(raw_status)
	if not is_valid(raw_status) then
		return nil, nil, nil, nil
	end

	local name = safe_get(raw_status, "name")
	local id = raw_status.id and tostring(raw_status.id) or nil
	local category = nil
	local color = nil

	local cat = safe_get(raw_status, "statusCategory")
	if is_valid(cat) then
		category = cat.name
		color = cat.colorName
	end

	return name, id, category, color
end

---@param raw_user table|nil
---@return IssueUser|nil
local function normalize_issue_user(raw_user)
	if type(raw_user) ~= "table" then
		return nil
	end

	local account_id = raw_user.accountId and tostring(raw_user.accountId) or ""
	local display_name = raw_user.displayName and tostring(raw_user.displayName) or ""
	if account_id == "" or display_name == "" then
		return nil
	end

	return {
		account_id = account_id,
		display_name = display_name,
		email = raw_user.emailAddress and tostring(raw_user.emailAddress) or "",
	}
end

---@param raw_parent table|nil
---@return Issue|nil
local function extract_parent(raw_parent)
	if not is_valid(raw_parent) or not raw_parent.key then
		return nil
	end

	local pf = raw_parent.fields or {}
	local status, status_id, status_category, status_color = extract_status(safe_get(pf, "status"))

	return {
		key = tostring(raw_parent.key),
		summary = tostring(pf.summary or ""),
		project = M.normalize_project(safe_get(pf, "project")),
		status = status,
		status_id = status_id,
		status_category = status_category,
		status_color = status_color,
		type = M.normalize_issue_type(safe_get(pf, "issuetype")),
		priority = safe_get(pf, "priority", "name"),
		assignee = normalize_issue_user(safe_get(pf, "assignee")),
		reporter = normalize_issue_user(safe_get(pf, "reporter")),
		story_points = nil,
		duedate = nil,
		parent = nil,
	}
end

---@param value any
---@return number|nil
local function extract_story_points(value)
	if not is_valid(value) then
		return nil
	end

	if type(value) == "number" then
		return value
	end

	if type(value) == "string" then
		local n = tonumber(value)
		if n then
			return n
		end
	end

	return nil
end

---@param raw table
---@param sp_field string|nil
---@return Issue
function M.normalize_issue(raw, sp_field)
	local fields = raw.fields or {}
	local status, status_id, status_category, status_color = extract_status(safe_get(fields, "status"))

	return {
		key = tostring(raw.key or ""),
		summary = tostring(fields.summary or ""),
		project = M.normalize_project(safe_get(fields, "project")),
		status = status,
		status_id = status_id,
		status_category = status_category,
		status_color = status_color,
		type = M.normalize_issue_type(safe_get(fields, "issuetype")),
		priority = safe_get(fields, "priority", "name"),
		assignee = normalize_issue_user(safe_get(fields, "assignee")),
		reporter = normalize_issue_user(safe_get(fields, "reporter")),
		story_points = sp_field and extract_story_points(fields[sp_field]) or nil,
		duedate = fields.duedate,
		parent = extract_parent(safe_get(fields, "parent")),
		is_subscribed = safe_get(fields, "watches", "isWatching") == true,
		_raw = raw,
	}
end

---@param raw_issues table[]
---@param sp_field string|nil
---@return Issue[]
function M.normalize_issues(raw_issues, sp_field)
	local out = {}
	for _, raw in ipairs(raw_issues or {}) do
		table.insert(out, M.normalize_issue(raw, sp_field))
	end
	return out
end

---@param raw_comment table|nil
---@param issue_key string|nil
---@param base_url string|nil
---@return IssueComment|nil
local function normalize_comment(raw_comment, issue_key, base_url)
	if type(raw_comment) ~= "table" then
		return nil
	end

	local parent_id = nil
	if type(raw_comment.parentId) == "number" or type(raw_comment.parentId) == "string" then
		parent_id = raw_comment.parentId
	end

	local comment_id = tostring(raw_comment.id or "")
	local url = nil
	if base_url and base_url ~= "" and issue_key and issue_key ~= "" and comment_id ~= "" then
		url = string.format("%s/browse/%s?focusedCommentId=%s", base_url, issue_key, comment_id)
	end

	return {
		id = comment_id,
		self = raw_comment.self and tostring(raw_comment.self) or nil,
		url = url,
		author = normalize_issue_user(raw_comment.author),
		body = adf.to_markdown(type(raw_comment.body) == "table" and raw_comment.body or nil),
		_body = type(raw_comment.body) == "table" and raw_comment.body or nil,
		created = raw_comment.created and tostring(raw_comment.created) or nil,
		updated = raw_comment.updated and tostring(raw_comment.updated) or nil,
		parent_id = parent_id,
		children = nil,
	}
end

---@param raw table|nil
---@param issue_key string|nil
---@return IssueComment[]
function M.normalize_comments(raw, issue_key)
	local service = require("atlas.issues.providers.jira.api.service")
	local base_url = tostring(service.jira_config().base_url or ""):gsub("/$", "")
	local comments = {}
	for _, raw_comment in ipairs((type(raw) == "table" and raw.comments) or {}) do
		local comment = normalize_comment(raw_comment, issue_key, base_url)
		if comment ~= nil then
			table.insert(comments, comment)
		end
	end
	return comments
end

---@param raw table|nil
---@param fallback_start_at number|nil
---@param fallback_max_results number|nil
---@return { start_at: number, max_results: number, total: number, is_last: boolean, values: IssueHistoryEntry[] }
function M.normalize_issue_history_page(raw, fallback_start_at, fallback_max_results)
	local values = {}
	for _, raw_entry in ipairs((type(raw) == "table" and raw.values) or {}) do
		if type(raw_entry) == "table" then
			local items = {}
			for _, raw_item in ipairs(raw_entry.items or {}) do
				if type(raw_item) == "table" then
					table.insert(items, {
						field = to_string_or_nil(raw_item.field),
						field_type = to_string_or_nil(raw_item.fieldtype),
						from = to_string_or_nil(raw_item.from),
						from_string = to_string_or_nil(raw_item.fromString),
						to = to_string_or_nil(raw_item.to),
						to_string = to_string_or_nil(raw_item.toString),
					})
				end
			end

			table.insert(values, {
				id = tostring(raw_entry.id or ""),
				created = raw_entry.created and tostring(raw_entry.created) or nil,
				author = normalize_issue_user(raw_entry.author),
				items = items,
			})
		end
	end

	return {
		start_at = tonumber(type(raw) == "table" and raw.startAt) or tonumber(fallback_start_at) or 0,
		max_results = tonumber(type(raw) == "table" and raw.maxResults) or tonumber(fallback_max_results) or 100,
		total = tonumber(type(raw) == "table" and raw.total) or #values,
		is_last = type(raw) == "table" and raw.isLast == true or false,
		values = values,
	}
end

return M
