local M = {}
local adf = require("atlas.issues.providers.jira.converted.adf")
local json = require("atlas.core.json")

---@param raw_project any Decoded API value.
---@return IssueProject|nil
function M.to_project(raw_project)
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

---@param raw_type any Decoded API value.
---@return IssueType|nil
function M.to_issue_type(raw_type)
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

---@param obj any Decoded API value.
---@param key string
---@param subkey string|nil
---@return any
local function safe_get(obj, key, subkey)
	obj = json.nilify(obj)
	if type(obj) ~= "table" then
		return nil
	end
	local val = json.nilify(obj[key])
	if subkey then
		if type(val) ~= "table" then
			return nil
		end
		return json.nilify(val[subkey])
	end
	return val
end

---@param value any
---@return string|nil
local function to_string_or_nil(value)
	return json.safe_str(value)
end

---@param raw_status any Decoded API value.
---@return string|nil, string|nil
local function extract_status(raw_status)
	raw_status = json.nilify(raw_status)
	if type(raw_status) ~= "table" then
		return nil, nil
	end

	local name = safe_get(raw_status, "name")
	local id = raw_status.id and tostring(raw_status.id) or nil
	return name, id
end

---@param raw_user any Decoded API value.
---@return IssueUser|nil
local function normalize_issue_user(raw_user)
	raw_user = json.nilify(raw_user)
	if type(raw_user) ~= "table" then
		return nil
	end

	-- Replace accountId with name to support Jira server instances
	local account_id = json.safe_str(raw_user.accountId) or json.safe_str(raw_user.name) or ""
	local display_name = json.safe_str(raw_user.displayName) or ""
	if account_id == "" or display_name == "" then
		return nil
	end
	return {
		account_id = account_id,
		display_name = display_name,
	}
end

---@param raw_parent any Decoded API value.
---@return Issue|nil
local function extract_parent(raw_parent)
	raw_parent = json.nilify(raw_parent)
	if type(raw_parent) ~= "table" or not raw_parent.key then
		return nil
	end

	local pf = raw_parent.fields or {}
	local status, status_id = extract_status(safe_get(pf, "status"))

	return {
		key = tostring(raw_parent.key),
		title = tostring(pf.summary or ""),
		project = M.to_project(safe_get(pf, "project")),
		status = status,
		status_id = status_id,
		type = M.to_issue_type(safe_get(pf, "issuetype")),
		priority = safe_get(pf, "priority", "name"),
		assignee = normalize_issue_user(safe_get(pf, "assignee")),
		reporter = normalize_issue_user(safe_get(pf, "reporter")),
		story_points = nil,
		duedate = nil,
		parent = nil,
	}
end

---@param raw_labels any
---@return IssueLabel[]
local function extract_labels(raw_labels)
	local labels = {}
	for _, name in ipairs(json.safe_table(raw_labels)) do
		if type(name) == "string" and name ~= "" then
			table.insert(labels, { name = name })
		end
	end
	return labels
end

---@param value any
---@return string
local function extract_description(value)
	value = json.nilify(value)
	if type(value) == "table" then
		return adf.to_markdown(value)
	end
	return json.safe_str(value) or ""
end

---@param value any
---@return number|nil
local function extract_story_points(value)
	value = json.nilify(value)
	if value == nil then
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
function M.to_issue(raw, sp_field)
	local fields = raw.fields or {}
	local status, status_id = extract_status(safe_get(fields, "status"))

	return {
		key = tostring(raw.key or ""),
		title = tostring(fields.summary or ""),
		project = M.to_project(safe_get(fields, "project")),
		status = status,
		status_id = status_id,
		type = M.to_issue_type(safe_get(fields, "issuetype")),
		priority = safe_get(fields, "priority", "name"),
		assignee = normalize_issue_user(safe_get(fields, "assignee")),
		reporter = normalize_issue_user(safe_get(fields, "reporter")),
		story_points = sp_field and extract_story_points(fields[sp_field]) or nil,
		duedate = to_string_or_nil(fields.duedate),
		parent = extract_parent(safe_get(fields, "parent")),
		created_at = json.safe_str(fields.created),
		updated_at = json.safe_str(fields.updated),
		closed_at = json.safe_str(fields.resolutiondate),
		comment_count = tonumber(safe_get(fields, "comment", "total")),
		is_subscribed = safe_get(fields, "watches", "isWatching") == true,
		_raw = raw,
	}
end

---@param raw table
---@param sp_field string|nil
---@return IssueDetails
function M.to_issue_details(raw, sp_field)
	local issue = M.to_issue(raw, sp_field)
	local fields = raw.fields or {}
	local assignee = normalize_issue_user(safe_get(fields, "assignee"))

	issue.description = extract_description(fields.description)
	issue.assignees = assignee and { assignee } or {}
	issue.labels = extract_labels(fields.labels)
	issue.milestone = nil
	issue.reactions = nil
	issue.sub_issues = {}
	return issue
end

---@param raw_issues table[]
---@param sp_field string|nil
---@return Issue[]
function M.to_issues_list(raw_issues, sp_field)
	local out = {}
	for _, raw in ipairs(raw_issues or {}) do
		table.insert(out, M.to_issue(raw, sp_field))
	end
	return out
end

---@class JiraCommentMappingContext
---@field issue_key? string
---@field base_url? string

---@param raw_comment any Decoded API value.
---@param context JiraCommentMappingContext
---@return IssueComment|nil
local function normalize_comment(raw_comment, context)
	if type(raw_comment) ~= "table" then
		return nil
	end

	local parent_id = nil
	if type(raw_comment.parentId) == "number" or type(raw_comment.parentId) == "string" then
		parent_id = raw_comment.parentId
	end

	local comment_id = tostring(raw_comment.id or "")
	local issue_key = tostring(context.issue_key or "")
	local base_url = tostring(context.base_url or ""):gsub("/+$", "")
	local url = nil
	if base_url ~= "" and issue_key ~= "" and comment_id ~= "" then
		url = string.format("%s/browse/%s?focusedCommentId=%s", base_url, issue_key, comment_id)
	end

	return {
		id = comment_id,
		self = raw_comment.self and tostring(raw_comment.self) or nil,
		url = url,
		author = normalize_issue_user(raw_comment.author),
		-- Jira cloud returns body as ADF, while Jira server returns it as string
		body = type(raw_comment.body) == "table" and adf.to_markdown(raw_comment.body)
			or type(raw_comment.body) == "string" and raw_comment.body
			or nil,
		created = raw_comment.created and tostring(raw_comment.created) or nil,
		updated = raw_comment.updated and tostring(raw_comment.updated) or nil,
		parent_id = parent_id,
		children = nil,
	}
end

---@param raw any Decoded API value.
---@param context JiraCommentMappingContext
---@return IssueComment[]
function M.to_comments_list(raw, context)
	local comments = {}
	for _, raw_comment in ipairs((type(raw) == "table" and raw.comments) or {}) do
		local comment = normalize_comment(raw_comment, context or {})
		if comment ~= nil then
			table.insert(comments, comment)
		end
	end
	return comments
end

local icons = require("atlas.ui.shared.icons")
local helper = require("atlas.issues.ui.presentation")

local FIELD_LABELS = {
	Comment = "a comment",
	issuetype = "issue type",
	timeoriginalestimate = "original estimate",
	timeestimate = "remaining estimate",
	timespent = "time spent",
	WorklogId = "worklog",
	IssueParentAssociation = "parent issue",
}

---@param seconds string|nil
---@return string
local function format_estimate(seconds)
	if seconds == nil or seconds == "" then
		return "0m"
	end
	local value = tonumber(seconds)
	if value == nil then
		return tostring(seconds)
	end
	local hours = math.floor(value / 3600)
	local minutes = math.floor((value % 3600) / 60)
	return hours > 0 and string.format("%dh %dm", hours, minutes) or string.format("%dm", minutes)
end

---@param from_hl string|nil
---@param to_hl string|nil
---@return IssueActivityBodyHlFn|nil
local function arrow_hl(from_hl, to_hl)
	if from_hl == nil and to_hl == nil then
		return nil
	end
	return function(row, _)
		local start_col, end_col = row:find(" -> ", 1, true)
		if not start_col then
			return nil
		end
		local spans = {}
		if from_hl then
			table.insert(spans, { start_col = 0, end_col = start_col - 1, hl_group = from_hl })
		end
		if to_hl then
			table.insert(spans, { start_col = end_col, end_col = #row, hl_group = to_hl })
		end
		return spans
	end
end

---@param raw_item table
---@param actor IssueUser|nil
---@param date string|nil
---@return IssueActivityEntry
local function activity_from_history_item(raw_item, actor, date)
	local field = to_string_or_nil(raw_item.field) or ""
	local from = to_string_or_nil(raw_item.fromString) or to_string_or_nil(raw_item.from)
	local to = to_string_or_nil(raw_item.toString) or to_string_or_nil(raw_item.to)
	local has_from = from ~= nil and vim.trim(from) ~= ""
	local has_to = to ~= nil and vim.trim(to) ~= ""
	local action = (has_from and not has_to) and "deleted" or (not has_from and has_to) and "added" or "updated"
	local body, body_hl

	if field == "description" then
		local old = has_from and vim.trim((from or ""):gsub("%s+", " ")) or ""
		local new = has_to and vim.trim((to or ""):gsub("%s+", " ")) or ""
		if #old > 200 then
			old = old:sub(1, 197) .. "..."
		end
		if #new > 200 then
			new = new:sub(1, 197) .. "..."
		end
		if old ~= "" and new ~= "" then
			body = string.format("%s\n\n↓\n\n%s", old, new)
			body_hl = function(row, row_index)
				if row_index == 1 then
					return { { start_col = 0, end_col = #row, hl_group = "AtlasTextMutedStrikethrough" } }
				end
			end
		elseif old ~= "" then
			body = old
			body_hl = function(row, _)
				return { { start_col = 0, end_col = #row, hl_group = "AtlasTextMutedStrikethrough" } }
			end
		elseif new ~= "" then
			body = new
		end
	elseif field == "assignee" then
		body = string.format("%s -> %s", from or "Unassigned", to or "Unassigned")
		body_hl = arrow_hl(helper.person_hl(from), helper.person_hl(to))
	elseif field == "priority" then
		local from_icon, from_hl = icons.issues_priority(from or "")
		local to_icon, to_hl = icons.issues_priority(to or "")
		body = string.format("%s %s -> %s %s", from_icon, from or "", to_icon, to or "")
		body_hl = arrow_hl(from_hl, to_hl)
	elseif field == "issuetype" then
		local from_icon, from_hl = icons.issues_type(from or "")
		local to_icon, to_hl = icons.issues_type(to or "")
		body = string.format("%s %s -> %s %s", from_icon, from or "", to_icon, to or "")
		body_hl = arrow_hl(from_hl, to_hl)
	elseif field == "status" then
		body = string.format("%s -> %s", from or "", to or "")
		body_hl =
			arrow_hl(helper.status_hl(to_string_or_nil(raw_item.from)), helper.status_hl(to_string_or_nil(raw_item.to)))
	elseif field == "timeoriginalestimate" or field == "timeestimate" or field == "timespent" then
		body = string.format("%s -> %s", format_estimate(from), format_estimate(to))
	elseif field == "IssueParentAssociation" then
		local old = has_from and from or "None"
		local new = has_to and to or "None"
		body = string.format("%s -> %s", old, new)
		body_hl = arrow_hl("AtlasJiraKey", "AtlasJiraKey")
	elseif field ~= "Comment" and (has_from or has_to) then
		body = string.format("%s -> %s", from or "", to or "")
	end

	return {
		kind = field ~= "" and field or "update",
		actor = actor,
		date = date,
		label = string.format("%s %s", action, FIELD_LABELS[field] or field),
		body = body,
		body_hl = body_hl,
	}
end

---@param raw any Decoded API value.
---@param fallback_start_at number|nil
---@param fallback_max_results number|nil
---@return { start_at: number, max_results: number, total: number, is_last: boolean, values: IssueActivityEntry[] }
function M.to_history_page(raw, fallback_start_at, fallback_max_results)
	local values = {}
	local histories = type(raw) == "table" and (raw.values or raw.histories) or {}
	for _, raw_entry in ipairs(type(histories) == "table" and histories or {}) do
		if type(raw_entry) == "table" then
			local actor = normalize_issue_user(raw_entry.author)
			local date = raw_entry.created and tostring(raw_entry.created) or nil
			for _, raw_item in ipairs(raw_entry.items or {}) do
				if type(raw_item) == "table" then
					table.insert(values, activity_from_history_item(raw_item, actor, date))
				end
			end
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
