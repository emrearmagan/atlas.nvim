local M = {}

local json = require("atlas.core.json")
local github_mapper = require("atlas.providers.github.mapper")

M.to_user = github_mapper.to_user

---@param raw_users table[]|nil
---@return AtlasUser[]
function M.to_users(raw_users)
	local users = {}
	for _, raw in ipairs(json.safe_table(raw_users)) do
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
---@return GitHubIssueMilestone|nil
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
		number = tonumber(raw.number),
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

	local _, _, slug = github_mapper.repository(raw.repository, fallback_slug)
	local key = slug ~= "" and string.format("%s#%d", slug, number) or string.format("#%d", number)
	return { key = key, title = json.safe_str(raw.title) }, slug, number
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
	local url = json.safe_str(raw.url) or ""
	local status_name, status_id = normalize_state(raw.state)
	local author = M.to_user(raw.author)

	local issue_assignees = github_mapper.connection_nodes(raw.assignees)
	local parent = issue_identity(json.nilify(raw.parent), fallback_slug)
	local subscription = json.safe_str(raw.viewerSubscription)
	local is_subscribed = subscription and subscription == "SUBSCRIBED"
	local created_at = json.safe_str(raw.createdAt) or ""
	local updated_at = json.safe_str(raw.updatedAt) or ""
	local closed_at = json.safe_str(raw.closedAt)
	local comment_count = tonumber(json.safe_table(raw.comments).totalCount) or 0

	---@type GitHubIssue
	local issue = {
		key = ref.key,
		repo_full_name = repo_full_name,
		number = number,
		title = ref.title or "",
		status = status_name,
		status_id = status_id,
		type = nil,
		assignee = M.to_users(issue_assignees)[1],
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
---@return GitHubIssueDetails|nil
function M.to_issue_details(raw, fallback_slug)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end

	---@type GitHubIssueDetails
	local details = {
		title = json.safe_str(raw.title),
		description = json.safe_str(raw.body) or "",
		reactions = github_mapper.graphql_reactions(raw.reactionGroups),
		assignees = M.to_users(github_mapper.connection_nodes(raw.assignees)),
		labels = labels(github_mapper.connection_nodes(raw.labels)),
		milestone = milestone(raw.milestone),
		sub_issues = {},
	}
	for _, child in ipairs(github_mapper.connection_nodes(raw.subIssues)) do
		local sub_issue = M.to_issue(child, fallback_slug)
		if sub_issue then
			table.insert(details.sub_issues, sub_issue)
		end
	end
	return details
end

---@param nodes table[]
---@return Issue[]
function M.to_search_results(nodes)
	local issues = {}
	for _, raw in ipairs(nodes) do
		local issue = M.to_issue(raw, nil)
		if issue then
			table.insert(issues, issue)
		end
	end
	return issues
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

local EVENT_LABELS = {
	ConnectedEvent = "linked a pull request",
	DisconnectedEvent = "unlinked a pull request",
	IssueTypeAddedEvent = "added the issue type",
	IssueTypeChangedEvent = "changed the issue type",
	IssueTypeRemovedEvent = "removed the issue type",
	MarkedAsDuplicateEvent = "marked as duplicate",
	MentionedEvent = "was mentioned",
	ParentIssueAddedEvent = "added a parent issue",
	ParentIssueRemovedEvent = "removed a parent issue",
	PinnedEvent = "pinned this issue",
	SubIssueAddedEvent = "added a sub-issue",
	SubIssueRemovedEvent = "removed a sub-issue",
	SubscribedEvent = "subscribed",
	TransferredEvent = "transferred",
	UnmarkedAsDuplicateEvent = "unmarked as duplicate",
	UnpinnedEvent = "unpinned this issue",
	UnsubscribedEvent = "unsubscribed",
}

---@param node any GraphQL timeline event
---@return IssueActivityEntry|nil
function M.to_timeline_entry(node)
	node = json.safe_table(node)
	local event = json.safe_str(node.__typename) or ""
	---@type IssueActivityEntry
	local entry = { kind = "other", actor = M.to_user(node.actor), date = json.safe_str(node.createdAt) or "" }

	if event == "LabeledEvent" or event == "UnlabeledEvent" then
		local name = json.safe_str(json.safe_table(node.label).name) or ""
		local verb = event == "LabeledEvent" and "added label" or "removed label"
		entry.kind = event == "LabeledEvent" and "labeled" or "unlabeled"
		entry.label = name ~= "" and (verb .. ": " .. name) or verb
	elseif event == "AssignedEvent" or event == "UnassignedEvent" then
		local login = json.safe_str(json.safe_table(node.assignee).login) or ""
		local verb = event == "AssignedEvent" and "assigned" or "unassigned"
		entry.kind = event == "AssignedEvent" and "assigned" or "unassigned"
		entry.label = login ~= "" and (verb .. " " .. login) or verb
	elseif event == "MilestonedEvent" or event == "DemilestonedEvent" then
		local title = json.safe_str(node.milestoneTitle) or ""
		local verb = event == "MilestonedEvent" and "added milestone" or "removed milestone"
		entry.kind = event == "MilestonedEvent" and "milestoned" or "demilestoned"
		entry.label = title ~= "" and (verb .. ": " .. title) or verb
	elseif event == "RenamedTitleEvent" then
		entry.kind = "renamed"
		local from = json.safe_str(node.previousTitle) or ""
		local to = json.safe_str(node.currentTitle) or ""
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
	elseif event == "CrossReferencedEvent" then
		entry.kind = "referenced"
		local source = json.safe_table(node.source)
		local title = json.safe_str(source.title) or ""
		local url = json.safe_str(source.url) or ""
		entry.label = "referenced"
		entry.body = title ~= "" and title or (url ~= "" and url or nil)
	elseif event == "ReferencedEvent" or event == "ClosedEvent" then
		local commit_id = json.safe_str(json.safe_table(event == "ClosedEvent" and node.closer or node.commit).oid)
		local short = (commit_id and commit_id ~= "") and commit_id:sub(1, 8) or nil
		entry.kind = event == "ClosedEvent" and "closed" or "referenced"
		entry.label = entry.kind
		if short then
			entry.body = "commit " .. short
			entry.body_hl = function(row, _)
				return { { start_col = 0, end_col = #row, hl_group = "AtlasTextMuted" } }
			end
		end
	elseif event == "ReopenedEvent" then
		entry.kind = "reopened"
		entry.label = "reopened"
	elseif event == "LockedEvent" or event == "UnlockedEvent" then
		entry.kind = event == "LockedEvent" and "locked" or "unlocked"
		entry.label = entry.kind .. " conversation"
	elseif EVENT_LABELS[event] then
		entry.label = EVENT_LABELS[event]
	else
		return nil
	end

	return entry
end

---@param node any GraphQL `IssueComment`
---@param author_login string|nil
---@return IssueComment|nil
function M.to_comment(node, author_login)
	node = json.safe_table(node)
	if json.nilify(node.id) == nil then
		return nil
	end
	return {
		id = tostring(node.id),
		url = json.safe_str(node.url) or "",
		author = M.to_user(node.author),
		author_roles = github_mapper.author_roles(node, author_login),
		body = json.safe_str(node.body) or "",
		created_at = json.safe_str(node.createdAt) or "",
		reactions = github_mapper.graphql_reactions(node.reactionGroups),
	}
end

return M
