local json = require("atlas.core.json")

local M = {}

---@param raw any
---@return IssueUser|nil
local function user(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local login = json.safe_str(raw.login) or ""
	if login == "" then
		return nil
	end
	local name = json.safe_str(raw.full_name) or ""
	return {
		id = tonumber(raw.id),
		account_id = login,
		display_name = name ~= "" and name or login,
	}
end

---@param raw any
---@return string
local function repo_slug(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return ""
	end
	local full_name = json.safe_str(raw.full_name) or ""
	if full_name ~= "" then
		return full_name
	end
	local owner_name = json.safe_str(raw.owner)
	local name = json.safe_str(raw.name)
	return owner_name and name and (owner_name .. "/" .. name) or ""
end

---@param values any
---@return table[]
local function labels(values)
	local result = {}
	for _, raw in ipairs(json.safe_table(json.nilify(values))) do
		if type(raw) == "table" and type(raw.name) == "string" and raw.name ~= "" then
			table.insert(result, {
				id = tonumber(raw.id),
				name = raw.name,
				color = json.safe_str(raw.color),
			})
		end
	end
	return result
end

local TIMELINE_EVENTS = {
	reopen = { "reopened", "reopened" },
	close = { "closed", "closed" },
	issue_ref = { "referenced", "referenced" },
	commit_ref = { "referenced", "referenced from a commit" },
	comment_ref = { "referenced", "referenced from a comment" },
	pull_ref = { "referenced", "referenced from a pull request" },
	lock = { "locked", "locked conversation" },
	unlock = { "unlocked", "unlocked conversation" },
	pin = { "pinned", "pinned" },
	unpin = { "unpinned", "unpinned" },
}

---@param value any
---@return string|nil
local function nonempty(value)
	local result = json.safe_str(value) or ""
	return result ~= "" and result or nil
end

---@param raw any
---@param field string
---@return string|nil
local function object_name(raw, field)
	raw = json.nilify(raw)
	return type(raw) == "table" and nonempty(raw[field]) or nil
end

---@param before string|nil
---@param after string|nil
---@return string|nil
local function change(before, after)
	if before and after then
		return before .. " → " .. after
	end
	return after or before
end

M.to_user = user

---@param raw any
---@param fallback_slug string|nil
---@return Issue|nil
function M.to_issue(raw, fallback_slug)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local number = tonumber(raw.number)
	if number == nil or type(json.nilify(raw.pull_request)) == "table" then
		return nil
	end

	local url = json.safe_str(raw.html_url) or ""
	local slug = repo_slug(raw.repository)
	if slug == "" then
		slug = tostring(fallback_slug or "")
	end
	if slug == "" then
		return nil
	end

	local state = tostring(raw.state or ""):lower() == "closed" and "closed" or "open"
	local assignees = json.safe_table(json.nilify(raw.assignees))
	local issue_labels = labels(raw.labels)
	local milestone = json.nilify(raw.milestone)
	if type(milestone) ~= "table" then
		milestone = nil
	end
	local reporter = user(raw.user)
	local original_author = nonempty(raw.original_author)
	if not reporter and original_author then
		reporter = {
			id = tonumber(raw.original_author_id),
			account_id = original_author,
			display_name = original_author,
		}
	end
	local due_date = nonempty(raw.due_date)
	local display_due_date = due_date and (due_date:match("^%d%d%d%d%-%d%d%-%d%d") or due_date) or nil

	return {
		key = string.format("%s#%d", slug, number),
		summary = json.safe_str(raw.title) or "",
		project = nil,
		status = state == "closed" and "Closed" or "Open",
		status_id = state,
		status_category = nil,
		status_color = nil,
		type = nil,
		priority = nil,
		assignee = user(assignees[1] or raw.assignee),
		reporter = reporter,
		story_points = nil,
		duedate = display_due_date,
		parent = nil,
		url = url ~= "" and url or nil,
		is_pinned = (tonumber(raw.pin_order) or 0) > 0,
		is_subscribed = nil,
		_raw = {
			number = number,
			project_path = slug,
			description = json.safe_str(raw.body) or "",
			created_at = json.safe_str(raw.created_at) or "",
			updated_at = json.safe_str(raw.updated_at),
			closed_at = json.safe_str(raw.closed_at),
			content_version = json.nilify(raw.content_version),
			is_locked = json.nilify(raw.is_locked),
			due_date = due_date,
			labels = issue_labels,
			assignees = assignees,
			milestone = milestone,
			comment_count = tonumber(raw.comments) or 0,
		},
	}
end

---@param raw any
---@return IssueComment|nil
function M.to_comment(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" or json.nilify(raw.id) == nil then
		return nil
	end
	return {
		id = tostring(raw.id),
		self = nil,
		url = json.safe_str(raw.html_url),
		author = user(raw.user),
		body = json.safe_str(raw.body) or "",
		created = json.safe_str(raw.created_at) or "",
		updated = json.safe_str(raw.updated_at),
		parent_id = nil,
		children = nil,
		reactions = nil,
	}
end

---@param raw any
---@return IssueActivityEntry|nil
function M.to_timeline_entry(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local raw_type = nonempty(raw.type)
	if raw_type == nil or raw_type == "comment" then
		return nil
	end

	local event = TIMELINE_EVENTS[raw_type]
	---@type IssueActivityEntry
	local entry = {
		kind = event and event[1] or raw_type,
		actor = user(raw.user),
		date = nonempty(raw.created_at),
		label = event and event[2] or raw_type:gsub("_", " "),
		body = nonempty(raw.body),
	}

	if raw_type == "label" then
		local added = tostring(json.nilify(raw.body) or "") == "1"
		entry.kind = added and "labeled" or "unlabeled"
		entry.label = added and "added label" or "removed label"
		entry.body = object_name(raw.label, "name")
	elseif raw_type == "milestone" then
		local before = object_name(raw.old_milestone, "title")
		local after = object_name(raw.milestone, "title")
		entry.kind = after and "milestoned" or "demilestoned"
		entry.label = after and (before and "changed milestone" or "added milestone") or "removed milestone"
		entry.body = change(before, after)
	elseif raw_type == "assignees" then
		local assignee = user(raw.assignee)
		local team = object_name(raw.assignee_team, "name")
		local removed = raw.removed_assignee == true
		entry.kind = removed and "unassigned" or "assigned"
		entry.label = removed and "unassigned" or "assigned"
		entry.body = assignee and assignee.display_name or team
	elseif raw_type == "change_title" then
		entry.kind = "renamed"
		entry.label = "renamed"
		entry.body = change(nonempty(raw.old_title), nonempty(raw.new_title))
	elseif raw_type == "change_issue_ref" or raw_type == "change_target_branch" then
		entry.label = raw_type == "change_issue_ref" and "changed issue reference" or "changed target branch"
		entry.body = change(nonempty(raw.old_ref), nonempty(raw.new_ref))
	elseif entry.kind == "referenced" then
		entry.body = object_name(raw.ref_issue, "title") or nonempty(raw.ref_commit_sha)
	elseif raw_type == "add_dependency" or raw_type == "remove_dependency" then
		entry.body = object_name(raw.dependent_issue, "title") or entry.body
	end

	return entry
end

---@param key string
---@return string, integer|nil
function M.parse_key(key)
	local slug, number = tostring(key or ""):match("^([^/]+/[^/]+)#(%d+)$")
	return slug or "", tonumber(number)
end

return M
