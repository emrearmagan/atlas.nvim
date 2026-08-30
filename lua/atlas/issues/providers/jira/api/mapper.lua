local M = {}
local adf = require("atlas.issues.providers.jira.converted.adf")
local json = require("atlas.core.json")

---@param raw_project any Decoded API value.
---@return JiraIssueProject|nil
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
---@return IssueRef|nil
local function extract_parent(raw_parent)
	raw_parent = json.nilify(raw_parent)
	if type(raw_parent) ~= "table" or not raw_parent.key then
		return nil
	end

	local pf = json.safe_table(raw_parent.fields)
	return {
		key = tostring(raw_parent.key),
		title = json.safe_str(pf.summary),
	}
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
---@return JiraIssue
function M.to_issue(raw, sp_field)
	local fields = json.safe_table(raw.fields)
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
		duedate = json.safe_str(fields.duedate),
		parent = extract_parent(safe_get(fields, "parent")),
		created_at = json.safe_str(fields.created),
		updated_at = json.safe_str(fields.updated),
		closed_at = json.safe_str(fields.resolutiondate),
		comment_count = tonumber(safe_get(fields, "comment", "total")),
		is_subscribed = safe_get(fields, "watches", "isWatching") == true,
	}
end

---@param raw table
---@param project_config AtlasJiraProjectFieldsConfig|nil
---@return JiraIssueDetails
function M.to_issue_details(raw, project_config)
	local fields = json.safe_table(raw.fields)
	local labels = {}
	for _, name in ipairs(json.safe_table(fields.labels)) do
		if type(name) == "string" and name ~= "" then
			table.insert(labels, { name = name })
		end
	end
	---@type JiraIssueDetails
	local details = {
		description = extract_description(fields.description),
		assignees = {},
		labels = labels,
		milestone = nil,
		raw_description = json.nilify(fields.description),
		custom_fields = {},
	}
	for field_id, field_config in pairs(project_config or {}) do
		local value = json.nilify(fields[field_id])
		if value ~= nil then
			local ok, formatted = pcall(field_config.format, value)
			if ok and formatted and formatted ~= "" then
				table.insert(details.custom_fields, {
					name = field_config.name or field_id,
					formatted = formatted,
					hl_group = field_config.hl_group,
					display = field_config.display or "chip",
				})
			end
		end
	end
	return details
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
	local payload = json.safe_table(raw)
	local comments = {}
	for _, raw_comment in ipairs(json.safe_table(payload.comments)) do
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
	local field = json.safe_str(raw_item.field) or ""
	local from = json.safe_str(raw_item.fromString) or json.safe_str(raw_item.from)
	local to = json.safe_str(raw_item.toString) or json.safe_str(raw_item.to)
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
		body_hl = arrow_hl(helper.status_hl(json.safe_str(raw_item.from)), helper.status_hl(json.safe_str(raw_item.to)))
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
---@return IssueActivityEntry[]
function M.to_history(raw)
	local payload = json.safe_table(raw)
	local entries = {}
	for _, raw_entry in ipairs(json.safe_table(payload.values or payload.histories)) do
		local entry = json.safe_table(raw_entry)
		local actor = normalize_issue_user(entry.author)
		local date = entry.created and tostring(entry.created) or nil
		for _, raw_item in ipairs(json.safe_table(entry.items)) do
			local item = json.safe_table(raw_item)
			if next(item) ~= nil then
				table.insert(entries, activity_from_history_item(item, actor, date))
			end
		end
	end

	return entries
end

return M
