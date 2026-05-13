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

---@param value any
---@return table
local function connection_nodes(value)
	value = nilify(value)
	if type(value) == "table" and type(value.nodes) == "table" then
		return value.nodes
	end
	return safe_table(value)
end

---@param raw_user table|nil
---@return IssueUser|nil
function M.normalize_user(raw_user)
	raw_user = nilify(raw_user)
	if type(raw_user) ~= "table" then
		return nil
	end
	local login = safe_str(raw_user.login) or ""
	if login == "" then
		return nil
	end
	local name = safe_str(raw_user.name) or ""
	local display_name = name ~= "" and name or login
	return {
		account_id = login,
		display_name = display_name,
		email = "",
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
	raw_groups = nilify(raw_groups)
	if type(raw_groups) ~= "table" then
		return nil
	end
	local out = {}
	for _, key in ipairs(REACTION_KEYS) do
		out[key] = 0
	end
	local any = false
	for _, group in ipairs(raw_groups) do
		local content = safe_str(group.content)
		local key = content and REACTION_GROUP_TO_KEY[content] or nil
		if key then
			local reactors = nilify(group.reactors)
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
	raw_repo = nilify(raw_repo)
	if type(raw_repo) == "table" then
		slug = safe_str(raw_repo.nameWithOwner) or safe_str(raw_repo.full_name) or ""
		if slug == "" then
			local owner_raw = nilify(raw_repo.owner)
			local owner = type(owner_raw) == "table" and (safe_str(owner_raw.login) or "") or ""
			local name = safe_str(raw_repo.name) or ""
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
function M.normalize_issue(raw, fallback_slug)
	raw = nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local number = tonumber(raw.number)
	if number == nil then
		return nil
	end

	local slug = extract_repo(raw.repository, fallback_slug)
	local url = safe_str(raw.url) or safe_str(raw.html_url) or ""
	if slug == "" then
		local extracted = url:match("github%.com/([^/]+/[^/]+)/issues/")
		if extracted then
			slug = extracted
		end
	end

	local key = slug ~= "" and string.format("%s#%d", slug, number) or string.format("#%d", number)
	local title = safe_str(raw.title) or ""
	local status_name, status_id = normalize_state(raw.state)
	local author = M.normalize_user(raw.author)

	local labels = connection_nodes(raw.labels)
	local assignees = connection_nodes(raw.assignees)
	local parent = M.normalize_issue(nilify(raw.parent), fallback_slug)
	local milestone = nilify(raw.milestone)
	local body = safe_str(raw.body) or ""
	local created_at = safe_str(raw.createdAt) or safe_str(raw.created_at) or ""
	local updated_at = safe_str(raw.updatedAt) or safe_str(raw.updated_at) or ""
	local closed_at = safe_str(raw.closedAt) or safe_str(raw.closed_at)

	local comments_field = nilify(raw.comments)
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
			node_id = safe_str(raw.id),
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
function M.normalize_issues(raw_list, fallback_slug)
	local out = {}
	for _, raw in ipairs(raw_list or {}) do
		local issue = M.normalize_issue(raw, fallback_slug)
		if issue ~= nil then
			table.insert(out, issue)
		end
	end
	return out
end

---@param nodes table[]|nil
---@return Issue[]
function M.normalize_graphql_search_results(nodes)
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
		local issue = M.normalize_issue(raw, nil)
		if type(issue) == "table" then
			insert_issue(issue.parent)
			insert_issue(issue)

			for _, child_raw in ipairs(connection_nodes(raw.subIssues)) do
				local child = M.normalize_issue(child_raw, nil)
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
	raw_reactions = nilify(raw_reactions)
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
function M.normalize_comment(raw)
	raw = nilify(raw)
	if type(raw) ~= "table" or nilify(raw.id) == nil then
		return nil
	end
	local user = nilify(raw.user)
	local author = nil
	if type(user) == "table" then
		local login = safe_str(user.login) or ""
		if login ~= "" then
			author = {
				account_id = login,
				display_name = login,
				email = "",
			}
		end
	end
	return {
		id = tostring(raw.id),
		self = nil,
		url = safe_str(raw.html_url) or "",
		author = author,
		body = safe_str(raw.body) or "",
		_body = nil,
		created = safe_str(raw.created_at) or "",
		updated = safe_str(raw.updated_at),
		parent_id = nil,
		children = nil,
		reactions = normalize_reactions(raw.reactions),
	}
end

---@param raw_list table[]|nil
---@return IssueComment[]
function M.normalize_comments(raw_list)
	local out = {}
	for _, raw in ipairs(raw_list or {}) do
		local c = M.normalize_comment(raw)
		if c ~= nil then
			table.insert(out, c)
		end
	end
	return out
end

return M
