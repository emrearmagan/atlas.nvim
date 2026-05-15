local M = {}

local json = require("atlas.core.json")

---@param value any
---@return table
local function connection_nodes(value)
	value = json.nilify(value)
	if type(value) == "table" and type(value.nodes) == "table" then
		return value.nodes
	end
	return json.safe_table(value)
end

---@param raw_user table|nil
---@return IssueUser|nil
function M.to_user(raw_user)
	raw_user = json.nilify(raw_user)
	if type(raw_user) ~= "table" then
		return nil
	end
	local login = json.safe_str(raw_user.login) or ""
	if login == "" then
		return nil
	end
	local name = json.safe_str(raw_user.name) or ""
	local display_name = name ~= "" and name or login
	return {
		account_id = login,
		display_name = display_name,
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

local REACTION_KEYS = { "+1", "-1", "laugh", "hooray", "confused", "heart", "rocket", "eyes" }

-- gh issue view --json reactionGroups returns:
--   [{ content = "THUMBS_UP", reactors = { totalCount = 3 } }, ...]
local REACTION_GROUP_TO_KEY = {
	THUMBS_UP = "+1",
	THUMBS_DOWN = "-1",
	LAUGH = "laugh",
	HOORAY = "hooray",
	CONFUSED = "confused",
	HEART = "heart",
	ROCKET = "rocket",
	EYES = "eyes",
}

---@param raw_groups any
---@return table<string, number>|nil
local function normalize_reaction_groups(raw_groups)
	raw_groups = json.nilify(raw_groups)
	if type(raw_groups) ~= "table" then
		return nil
	end
	local out = {}
	for _, key in ipairs(REACTION_KEYS) do
		out[key] = 0
	end
	local any = false
	for _, group in ipairs(raw_groups) do
		local content = json.safe_str(group.content)
		local key = content and REACTION_GROUP_TO_KEY[content] or nil
		if key then
			local reactors = json.nilify(group.reactors)
			local count = type(reactors) == "table" and tonumber(reactors.totalCount) or 0
			out[key] = (out[key] or 0) + count
			if count > 0 then
				any = true
			end
		end
	end
	return any and out or nil
end

---@param raw_repo table|nil
---@param fallback_slug string|nil
---@return string slug, string owner, string repo
local function extract_repo(raw_repo, fallback_slug)
	local slug = ""
	raw_repo = json.nilify(raw_repo)
	if type(raw_repo) == "table" then
		slug = json.safe_str(raw_repo.nameWithOwner) or json.safe_str(raw_repo.full_name) or ""
		if slug == "" then
			local owner_raw = json.nilify(raw_repo.owner)
			local owner = type(owner_raw) == "table" and (json.safe_str(owner_raw.login) or "") or ""
			local name = json.safe_str(raw_repo.name) or ""
			if owner ~= "" and name ~= "" then
				slug = owner .. "/" .. name
			end
		end
	end
	if slug == "" then
		slug = tostring(fallback_slug or "")
	end
	local owner_part, repo_part = slug:match("^([^/]+)/(.+)$")
	return slug, owner_part or "", repo_part or ""
end

---@param raw table
---@param fallback_slug string|nil
---@return Issue|nil
function M.to_issue(raw, fallback_slug)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local number = tonumber(raw.number)
	if number == nil then
		return nil
	end

	local slug = extract_repo(raw.repository, fallback_slug)
	local url = json.safe_str(raw.url) or json.safe_str(raw.html_url) or ""
	if slug == "" then
		local extracted = url:match("github%.com/([^/]+/[^/]+)/issues/")
		if extracted then
			slug = extracted
		end
	end

	local key = slug ~= "" and string.format("%s#%d", slug, number) or string.format("#%d", number)
	local title = json.safe_str(raw.title) or ""
	local status_name, status_id = normalize_state(raw.state)
	local author = M.to_user(raw.author)

	local labels = connection_nodes(raw.labels)
	local assignees = connection_nodes(raw.assignees)
	local parent = M.to_issue(json.nilify(raw.parent), fallback_slug)
	local milestone = json.nilify(raw.milestone)
	local body = json.safe_str(raw.body) or ""
	local created_at = json.safe_str(raw.createdAt) or json.safe_str(raw.created_at) or ""
	local updated_at = json.safe_str(raw.updatedAt) or json.safe_str(raw.updated_at) or ""
	local closed_at = json.safe_str(raw.closedAt) or json.safe_str(raw.closed_at)

	local comments_field = json.nilify(raw.comments)
	local comment_count = tonumber(raw.commentsCount)
		or (type(comments_field) == "number" and comments_field)
		or (type(comments_field) == "table" and tonumber(comments_field.totalCount))
		or (type(comments_field) == "table" and #comments_field)
		or 0

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
		reporter = author,
		story_points = nil,
		duedate = nil,
		parent = parent,
		url = url ~= "" and url or nil,
		is_pinned = raw.isPinned == true,
		is_subscribed = tostring(raw.viewerSubscription or "") == "SUBSCRIBED",
		_raw = {
			node_id = json.safe_str(raw.id),
			number = number,
			slug = slug,
			body = body,
			created_at = created_at,
			updated_at = updated_at,
			closed_at = closed_at,
			labels = labels,
			assignees = assignees,
			milestone = milestone,
			comment_count = comment_count,
			html_url = url,
			reactions = normalize_reaction_groups(raw.reactionGroups),
			sub_issues = connection_nodes(raw.subIssues),
		},
	}
	return issue
end

---@param raw_list table[]|nil
---@param fallback_slug string|nil
---@return Issue[]
function M.to_issues_list(raw_list, fallback_slug)
	local out = {}
	for _, raw in ipairs(raw_list or {}) do
		local issue = M.to_issue(raw, fallback_slug)
		if issue ~= nil then
			table.insert(out, issue)
		end
	end
	return out
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
			insert_issue(issue.parent)
			insert_issue(issue)

			for _, child_raw in ipairs(connection_nodes(raw.subIssues)) do
				local child = M.to_issue(child_raw, nil)
				if type(child) == "table" and child.parent == nil then
					child.parent = issue
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

---@param raw_reactions any
---@return table<string, number>|nil
local function normalize_reactions(raw_reactions)
	raw_reactions = json.nilify(raw_reactions)
	if type(raw_reactions) ~= "table" then
		return nil
	end
	local out = {}
	local any = false
	for _, key in ipairs(REACTION_KEYS) do
		local count = tonumber(raw_reactions[key]) or 0
		out[key] = count
		if count > 0 then
			any = true
		end
	end
	return any and out or nil
end

---@param raw table
---@return IssueComment|nil
function M.to_comment(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" or json.nilify(raw.id) == nil then
		return nil
	end
	local user = json.nilify(raw.user)
	local author = nil
	if type(user) == "table" then
		local login = json.safe_str(user.login) or ""
		if login ~= "" then
			author = {
				account_id = login,
				display_name = login,
			}
		end
	end
	return {
		id = tostring(raw.id),
		self = nil,
		url = json.safe_str(raw.html_url) or "",
		author = author,
		body = json.safe_str(raw.body) or "",
		_body = nil,
		created = json.safe_str(raw.created_at) or "",
		updated = json.safe_str(raw.updated_at),
		parent_id = nil,
		children = nil,
		reactions = normalize_reactions(raw.reactions),
	}
end

---@param raw_list table[]|nil
---@return IssueComment[]
function M.to_comments_list(raw_list)
	local out = {}
	for _, raw in ipairs(raw_list or {}) do
		local c = M.to_comment(raw)
		if c ~= nil then
			table.insert(out, c)
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Provider specific types
--------------------------------------------------------------------------------

---@param hex string|nil
---@return string|nil
local function label_hl_group(hex)
	if type(hex) ~= "string" or hex == "" then
		return nil
	end
	local clean = hex:lower():gsub("[^0-9a-f]", "")
	if #clean ~= 6 then
		return nil
	end
	local name = "AtlasGHIssueLabel_" .. clean
	pcall(vim.api.nvim_set_hl, 0, name, { fg = "#" .. clean, bold = true })
	return name
end

---@param raw table
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
		local color = type(label) == "table" and (json.safe_str(label.color) or "") or ""
		entry.label = event == "labeled" and "added label" or "removed label"
		if name ~= "" then
			entry.body = name
			local hl = label_hl_group(color)
			if hl then
				entry.body_hl = function(row, _)
					return { { start_col = 0, end_col = #row, hl_group = hl } }
				end
			end
		end
	elseif event == "assigned" or event == "unassigned" then
		local assignee = json.nilify(raw.assignee)
		local login = type(assignee) == "table" and (json.safe_str(assignee.login) or "") or ""
		entry.label = event == "assigned" and "assigned" or "unassigned"
		entry.body = login ~= "" and login or nil
	elseif event == "milestoned" or event == "demilestoned" then
		local milestone = json.nilify(raw.milestone)
		local title = type(milestone) == "table" and (json.safe_str(milestone.title) or "") or ""
		entry.label = event == "milestoned" and "added milestone" or "removed milestone"
		entry.body = title ~= "" and title or nil
	elseif event == "renamed" then
		local rename = json.nilify(raw.rename)
		local from = type(rename) == "table" and (json.safe_str(rename.from) or "") or ""
		local to = type(rename) == "table" and (json.safe_str(rename.to) or "") or ""
		entry.label = "renamed"
		if from ~= "" or to ~= "" then
			entry.body = from .. " → " .. to
			entry.body_hl = function(row, _)
				local s, e = row:find(" → ", 1, true)
				if not s then
					return nil
				end
				return {
					{ start_col = 0, end_col = s - 1, hl_group = "AtlasTextWarning" },
					{ start_col = e, end_col = #row, hl_group = "AtlasTextPositive" },
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
	elseif event == "reopened" then
		entry.label = "reopened"
	elseif event == "locked" then
		entry.label = "locked conversation"
	elseif event == "unlocked" then
		entry.label = "unlocked conversation"
	elseif event == "pinned" then
		entry.label = "pinned this issue"
	elseif event == "unpinned" then
		entry.label = "unpinned this issue"
	elseif event == "transferred" then
		entry.label = "transferred"
	elseif event == "marked_as_duplicate" then
		entry.label = "marked as duplicate"
	elseif event == "ready_for_review" then
		entry.label = "marked as ready for review"
	elseif event == "convert_to_draft" then
		entry.label = "marked as draft"
	elseif event == "head_ref_force_pushed" then
		entry.label = "force pushed"
	elseif event == "base_ref_force_pushed" then
		entry.label = "base branch force pushed"
	elseif event == "review_requested" then
		entry.label = "requested a review"
	elseif event == "reviewed" then
		entry.label = "reviewed"
	elseif event == "committed" then
		entry.label = "added a commit"
	elseif event == "subscribed" then
		entry.label = "subscribed"
	elseif event == "unsubscribed" then
		entry.label = "unsubscribed"
	elseif event == "mentioned" then
		entry.label = "was mentioned"
	elseif event == "comment_deleted" then
		entry.label = "deleted a comment"
	elseif event == "connected" then
		entry.label = "linked a pull request"
	elseif event == "disconnected" then
		entry.label = "unlinked a pull request"
	elseif event == "parent_issue_added" then
		entry.label = "added a parent issue"
	elseif event == "parent_issue_removed" then
		entry.label = "removed a parent issue"
	elseif event == "sub_issue_added" then
		entry.label = "added a sub-issue"
	elseif event == "sub_issue_removed" then
		entry.label = "removed a sub-issue"
	elseif event == "added_to_project_v2" then
		entry.label = "added to a project"
	elseif event == "removed_from_project_v2" then
		entry.label = "removed from a project"
	elseif event == "project_v2_item_status_changed" then
		entry.label = "changed project status"
	elseif event == "blocking_added" then
		entry.label = "added a blocker"
	elseif event == "blocking_removed" then
		entry.label = "removed a blocker"
	else
		entry.label = event
	end

	return entry
end

---@param raw table
---@return IssueComment|nil
function M.to_timeline_comment(raw)
	local comment = {}
	for key, value in pairs(raw) do
		comment[key] = value
	end
	if json.nilify(comment.user) == nil then
		comment.user = json.nilify(raw.actor)
	end
	return M.to_comment(comment)
end

return M
