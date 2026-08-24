local M = {}

local json = require("atlas.core.json")
local github_mapping = require("atlas.providers.github.mapping")

---@param raw_user any Decoded API value.
---@return IssueUser|nil
function M.to_user(raw_user)
	local user = github_mapping.identity(raw_user)
	if user == nil or user.login == "" then
		return nil
	end
	return { account_id = user.login, display_name = user.name }
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
		local name = json.safe_str(raw.name)
		if name then
			table.insert(result, { name = name, color = json.safe_str(raw.color) })
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
	return {
		title = title,
		progress_percentage = tonumber(raw.progressPercentage),
		open_issues = tonumber((raw.openIssues or {}).totalCount),
		closed_issues = tonumber((raw.closedIssues or {}).totalCount),
	}
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

---@param raw any Decoded API value.
---@param fallback_slug string|nil
---@return IssueRef|nil, string, integer|nil
local function issue_identity(raw, fallback_slug)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil, "", nil
	end

	local number = tonumber(raw.number)
	if number == nil then
		return nil, "", nil
	end

	local _, _, slug = github_mapping.repository(raw.repository, fallback_slug)
	local url = json.safe_str(raw.url) or json.safe_str(raw.html_url) or ""
	if slug == "" then
		slug = url:match("github%.com/([^/]+/[^/]+)/issues/") or ""
	end

	local key = slug ~= "" and string.format("%s#%d", slug, number) or string.format("#%d", number)
	return { key = key, title = json.safe_str(raw.title) }, slug, number
end

---@param raw any Decoded API value.
---@param fallback_slug string|nil
---@return IssueRef|nil
local function to_issue_ref(raw, fallback_slug)
	local ref = issue_identity(raw, fallback_slug)
	return ref
end

---@param raw any Decoded API value.
---@param fallback_slug string|nil
---@return GitHubIssue|nil
function M.to_issue(raw, fallback_slug)
	raw = json.nilify(raw)
	local ref, repo_full_name, number = issue_identity(raw, fallback_slug)
	if ref == nil or number == nil then
		return nil
	end
	local url = json.safe_str(raw.url) or json.safe_str(raw.html_url) or ""
	local status_name, status_id = normalize_state(raw.state)
	local author = M.to_user(raw.author)

	local issue_assignees = github_mapping.connection_nodes(raw.assignees)
	local parent = to_issue_ref(json.nilify(raw.parent), fallback_slug)
	local subscription = json.safe_str(raw.viewerSubscription)
	local is_subscribed = subscription and subscription == "SUBSCRIBED"
	local created_at = json.safe_str(raw.createdAt) or json.safe_str(raw.created_at) or ""
	local updated_at = json.safe_str(raw.updatedAt) or json.safe_str(raw.updated_at) or ""
	local closed_at = json.safe_str(raw.closedAt) or json.safe_str(raw.closed_at)

	local comments_field = json.nilify(raw.comments)
	local comment_count = tonumber(raw.commentsCount)
		or (type(comments_field) == "number" and comments_field)
		or (type(comments_field) == "table" and tonumber(comments_field.totalCount))
		or (type(comments_field) == "table" and #comments_field)
		or 0

	---@type GitHubIssue
	local issue = {
		key = ref.key,
		repo_full_name = repo_full_name,
		number = number,
		title = ref.title or "",
		status = status_name,
		status_id = status_id,
		type = nil,
		assignee = first_assignee(issue_assignees),
		reporter = author,
		story_points = nil,
		duedate = nil,
		parent = parent,
		url = url ~= "" and url or nil,
		created_at = created_at ~= "" and created_at or nil,
		updated_at = updated_at ~= "" and updated_at or nil,
		closed_at = closed_at,
		comment_count = comment_count,
		is_pinned = raw.isPinned == true,
		is_subscribed = is_subscribed,
		node_id = json.safe_str(raw.id),
	}
	return issue
end

---@param raw any Decoded API value.
---@param fallback_slug string|nil
---@return IssueDetails|nil
function M.to_issue_details(raw, fallback_slug)
	local issue = M.to_issue(raw, fallback_slug)
	if issue == nil then
		return nil
	end

	issue.description = json.safe_str(raw.body) or ""
	issue.assignees = assignees(github_mapping.connection_nodes(raw.assignees))
	issue.labels = labels(github_mapping.connection_nodes(raw.labels))
	issue.milestone = milestone(raw.milestone)
	issue.reactions = github_mapping.reaction_groups(raw.reactionGroups)
	issue.sub_issues = {}
	for _, child in ipairs(github_mapping.connection_nodes(raw.subIssues)) do
		local sub_issue = M.to_issue(child, fallback_slug)
		if sub_issue then
			table.insert(issue.sub_issues, sub_issue)
		end
	end
	return issue
end

---@param nodes table[]|nil
---@return Issue[]
function M.to_search_results(nodes)
	local out = {}
	local seen = {}

	local function insert_issue(issue)
		local key = type(issue) == "table" and tostring(issue.key or "") or ""
		if key == "" or seen[key] then
			return
		end
		seen[key] = true
		table.insert(out, issue)
	end

	for _, raw in ipairs(nodes or {}) do
		local issue = M.to_issue(raw, nil)
		if type(issue) == "table" then
			insert_issue(issue)

			for _, child_raw in ipairs(github_mapping.connection_nodes(raw.subIssues)) do
				local child = M.to_issue(child_raw, nil)
				if type(child) == "table" and child.parent == nil then
					child.parent = { key = issue.key, title = issue.title }
				end
				insert_issue(child)
			end
		end
	end

	return out
end

---@param key string
---@return string slug, integer|nil number
function M.parse_key(key)
	local k = tostring(key or "")
	local slug, num = k:match("^(.-)#(%d+)$")
	if slug and num then
		return slug, tonumber(num)
	end
	return "", nil
end

---@param raw any Decoded API value.
---@param raw_user any
---@return IssueComment|nil
local function to_comment(raw, raw_user)
	raw = json.nilify(raw)
	if type(raw) ~= "table" or json.nilify(raw.id) == nil then
		return nil
	end
	local user = github_mapping.identity(raw_user)
	local author = user and user.login ~= "" and { account_id = user.login, display_name = user.login } or nil
	return {
		id = tostring(raw.id),
		self = nil,
		url = json.safe_str(raw.html_url) or "",
		author = author,
		body = json.safe_str(raw.body) or "",
		created = json.safe_str(raw.created_at) or "",
		updated = json.safe_str(raw.updated_at),
		parent_id = nil,
		children = nil,
		reactions = github_mapping.reaction_counts(raw.reactions),
	}
end

---@param raw any Decoded API value.
---@return IssueComment|nil
function M.to_comment(raw)
	return to_comment(raw, type(raw) == "table" and raw.user or nil)
end

local EVENT_LABELS = {
	reopened = "reopened",
	locked = "locked conversation",
	unlocked = "unlocked conversation",
	pinned = "pinned this issue",
	unpinned = "unpinned this issue",
	transferred = "transferred",
	marked_as_duplicate = "marked as duplicate",
	ready_for_review = "marked as ready for review",
	convert_to_draft = "marked as draft",
	head_ref_force_pushed = "force pushed",
	base_ref_force_pushed = "base branch force pushed",
	review_requested = "requested a review",
	reviewed = "reviewed",
	committed = "added a commit",
	subscribed = "subscribed",
	unsubscribed = "unsubscribed",
	mentioned = "was mentioned",
	comment_deleted = "deleted a comment",
	connected = "linked a pull request",
	disconnected = "unlinked a pull request",
	parent_issue_added = "added a parent issue",
	parent_issue_removed = "removed a parent issue",
	sub_issue_added = "added a sub-issue",
	sub_issue_removed = "removed a sub-issue",
	added_to_project_v2 = "added to a project",
	removed_from_project_v2 = "removed from a project",
	project_v2_item_status_changed = "changed project status",
	blocking_added = "added a blocker",
	blocking_removed = "removed a blocker",
}

---@param raw any Decoded API value.
---@return IssueActivityEntry|nil
function M.to_timeline_entry(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local event = json.safe_str(raw.event) or ""
	if event == "" then
		return nil
	end

	local actor = M.to_user(raw.actor) or M.to_user(raw.user)
	local date = json.safe_str(raw.created_at) or ""

	---@type IssueActivityEntry
	local entry = { kind = event, actor = actor, date = date }

	if event == "commented" then
		local body = json.safe_str(raw.body) or ""
		entry.label = "commented"
		entry.body = body ~= "" and body or nil
	elseif event == "labeled" or event == "unlabeled" then
		local label = json.nilify(raw.label)
		local name = type(label) == "table" and (json.safe_str(label.name) or "") or ""
		local verb = event == "labeled" and "added label" or "removed label"
		entry.label = name ~= "" and (verb .. ": " .. name) or verb
	elseif event == "assigned" or event == "unassigned" then
		local assignee = json.nilify(raw.assignee)
		local login = type(assignee) == "table" and (json.safe_str(assignee.login) or "") or ""
		local verb = event == "assigned" and "assigned" or "unassigned"
		entry.label = login ~= "" and (verb .. " " .. login) or verb
	elseif event == "milestoned" or event == "demilestoned" then
		local event_milestone = json.nilify(raw.milestone)
		local title = type(event_milestone) == "table" and (json.safe_str(event_milestone.title) or "") or ""
		local verb = event == "milestoned" and "added milestone" or "removed milestone"
		entry.label = title ~= "" and (verb .. ": " .. title) or verb
	elseif event == "renamed" then
		local rename = json.nilify(raw.rename)
		local from = type(rename) == "table" and (json.safe_str(rename.from) or "") or ""
		local to = type(rename) == "table" and (json.safe_str(rename.to) or "") or ""
		entry.label = "renamed"
		if from ~= "" or to ~= "" then
			entry.body = from .. " → " .. to
			entry.body_hl = function(row, _)
				local start, finish = row:find(" → ", 1, true)
				if not start then
					return nil
				end
				return {
					{ start_col = 0, end_col = start - 1, hl_group = "AtlasTextMuted" },
					{ start_col = finish, end_col = #row, hl_group = "Normal" },
				}
			end
		end
	elseif event == "cross-referenced" then
		local source = json.nilify(raw.source)
		source = type(source) == "table" and source or {}
		local issue = json.nilify(source.issue)
		issue = type(issue) == "table" and issue or {}
		local title = json.safe_str(issue.title) or ""
		local url = json.safe_str(issue.html_url) or ""
		entry.label = "referenced"
		entry.body = title ~= "" and title or (url ~= "" and url or nil)
	elseif event == "referenced" or event == "closed" then
		local commit_id = json.safe_str(raw.commit_id)
		local short = (commit_id and commit_id ~= "") and commit_id:sub(1, 8) or nil
		entry.label = event == "closed" and "closed" or "referenced"
		if short then
			entry.body = "commit " .. short
			entry.body_hl = function(row, _)
				return { { start_col = 0, end_col = #row, hl_group = "AtlasTextMuted" } }
			end
		end
	else
		entry.label = EVENT_LABELS[event] or event
	end

	return entry
end

---@param raw table
---@return IssueComment|nil
function M.to_timeline_comment(raw)
	return to_comment(raw, json.nilify(raw.user) or json.nilify(raw.actor))
end

return M
