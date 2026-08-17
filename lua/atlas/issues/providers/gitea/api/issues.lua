local service = require("atlas.providers.gitea.client").issues
local pagination = require("atlas.issues.providers.gitea.api.pagination")
local json = require("atlas.core.json")
local request_scope = require("atlas.core.requests")
local mapper = require("atlas.issues.providers.gitea.api.mapper")

local M = {}

---@param slug string|nil
---@return string|nil
local function repo_endpoint(slug)
	local owner, repo = vim.trim(tostring(slug or "")):match("^([^/%s]+)/([^/%s]+)$")
	if not owner then
		return nil
	end
	return string.format("/repos/%s/%s", service.url_encode(owner), service.url_encode(repo))
end

---@param key string
---@return string|nil, integer|nil, string|nil
local function issue_endpoint(key)
	local slug, number = mapper.parse_key(key)
	local base = repo_endpoint(slug)
	if not base or not number then
		return nil, nil, nil
	end
	return string.format("%s/issues/%d", base, number), number, slug
end

---@param raw any
---@param fallback_slug string|nil
---@return Issue[]|nil, string|nil
local function map_issues(raw, fallback_slug)
	if not json.is_list(raw) then
		return nil, "Invalid Gitea/Forgejo issues response"
	end
	local issues = {}
	for _, value in ipairs(raw) do
		if json.nilify(json.safe_table(value).pull_request) == nil then
			local issue = mapper.to_issue(value, fallback_slug)
			if not issue then
				return nil, "Invalid Gitea/Forgejo issue response"
			end
			table.insert(issues, issue)
		end
	end
	return issues, nil
end

---@param raw any
---@param name string
---@return table[]|nil, string|nil
local function expect_list(raw, name)
	if not json.is_list(raw) then
		return nil, string.format("Invalid Gitea/Forgejo %s response", name)
	end
	return raw, nil
end

---@param raw any
---@return table|nil
local function map_label(raw)
	raw = json.safe_table(json.nilify(raw))
	local name = json.safe_str(raw.name)
	if not name or name == "" then
		return nil
	end
	return {
		id = tonumber(raw.id),
		name = name,
		color = json.safe_str(raw.color),
	}
end

---@param raw any
---@return table|nil
local function map_milestone(raw)
	raw = json.safe_table(json.nilify(raw))
	local id = tonumber(raw.id)
	local title = json.safe_str(raw.title)
	if not id or not title then
		return nil
	end
	return { id = id, title = title }
end

---@param on_done fun(user: IssueUser|nil, err: string|nil)
function M.fetch_user(on_done)
	return service.request("GET", "/user", nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local user = mapper.to_user(raw)
		if not user then
			on_done(nil, "Invalid Gitea/Forgejo user response")
			return
		end
		on_done(user, nil)
	end)
end

---@param view AtlasGiteaForgejoIssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[]|nil, next_page_token: string|nil, is_last: boolean, err: string|nil)
function M.list(view, opts, on_done)
	view = view or {}
	opts = opts or {}
	local page = math.max(1, tonumber(opts.next_page_token) or 1)
	local limit = math.max(1, math.min(50, tonumber(opts.max_results) or 50))
	local scope = tostring(view.scope or "")
	local has_scoped_filter = scope == "assigned" or scope == "created" or scope == "mentioned"
	if scope ~= "" and scope ~= "all" and scope ~= "assigned" and scope ~= "created" and scope ~= "mentioned" then
		on_done(nil, nil, true, "Invalid Gitea/Forgejo issue scope: " .. scope)
		return nil
	end
	local repo = vim.trim(tostring(view.repo or ""))
	local base = repo_endpoint(repo)
	if repo ~= "" and not base then
		on_done(nil, nil, true, "Invalid Gitea/Forgejo repository")
		return nil
	end
	local owner = vim.trim(tostring(view.owner or ""))
	local team = vim.trim(tostring(view.team or ""))
	local api_type = service.api_type()
	if team ~= "" and owner == "" then
		on_done(nil, nil, true, "Gitea/Forgejo issue team filter requires owner")
		return nil
	end
	local endpoint = base and (base .. "/issues") or "/repos/issues/search"
	local params = {
		state = view.state or "open",
		type = "issues",
		page = page,
		limit = limit,
		q = view.search,
		labels = view.labels,
		milestones = view.milestones,
		since = view.since,
		before = view.before,
		sort = api_type == "forgejo" and view.sort or nil,
	}

	if not base then
		params.assigned = scope == "assigned" or nil
		params.created = scope == "created" or nil
		params.mentioned = scope == "mentioned" or nil
		params.owner = owner ~= "" and owner or nil
		params.team = team ~= "" and team or nil
		params.created_by = api_type == "gitea" and view.created_by or nil
		params.priority_repo_id = api_type == "forgejo" and view.priority_repo_id or nil
	end

	local function fetch(done)
		return service.request("GET", endpoint .. service.query(params), nil, done)
	end
	local function finish(raw, err)
		if err then
			on_done(nil, nil, true, err)
			return
		end
		local issues, map_err = map_issues(raw, base and repo or nil)
		if map_err then
			on_done(nil, nil, true, map_err)
			return
		end
		-- The instance may clamp `limit` below Atlas's requested size.
		local has_next = #raw > 0
		on_done(issues, has_next and tostring(page + 1) or nil, not has_next, nil)
	end

	if base and has_scoped_filter then
		local requests = request_scope.new()
		requests.run(M.fetch_user, function(user, err)
			if err or not user or vim.trim(tostring(user.account_id or "")) == "" then
				on_done(nil, nil, true, err or "Could not determine the current Gitea/Forgejo user")
				return
			end
			local login = user.account_id
			params.assigned_by = scope == "assigned" and login or nil
			params.created_by = scope == "created" and login or nil
			params.mentioned_by = scope == "mentioned" and login or nil
			requests.run(fetch, finish)
		end)
		return requests
	end

	return fetch(finish)
end

---@param key string
---@param _ table|nil
---@param on_done fun(issue: Issue|nil, err: string|nil)
function M.get(key, _, on_done)
	local endpoint, _, slug = issue_endpoint(key)
	if not endpoint then
		on_done(nil, "Invalid Gitea/Forgejo issue key: " .. tostring(key))
		return nil
	end
	return service.request("GET", endpoint, nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local issue = mapper.to_issue(raw, slug)
		if not issue then
			on_done(nil, "The requested number is not an issue")
			return
		end
		on_done(issue, nil)
	end)
end

---@param opts { repo_slug: string, title: string, body: string|nil, labels: integer[]|nil, assignees: string[]|nil, milestone: integer|nil, due_date: string|nil }
---@param on_done fun(result: table|nil, err: string|nil)
function M.create(opts, on_done)
	local slug = vim.trim(tostring(opts and opts.repo_slug or ""))
	local base = repo_endpoint(slug)
	local title = vim.trim(tostring(opts and opts.title or ""))
	if not base or title == "" then
		on_done(nil, not base and "Invalid Gitea/Forgejo repository" or "Title is required")
		return nil
	end
	return service.request("POST", base .. "/issues", {
		title = title,
		body = tostring(opts.body or ""),
		labels = opts.labels,
		assignees = opts.assignees,
		milestone = opts.milestone,
		due_date = opts.due_date,
	}, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local issue = mapper.to_issue(raw, slug)
		if not issue then
			on_done(nil, "Invalid Gitea/Forgejo create issue response")
			return
		end
		on_done({ number = issue._raw.number, key = issue.key, url = issue.url, issue = issue }, nil)
	end)
end

---@param key string
---@param changes table
---@param on_done fun(issue: Issue|nil, err: string|nil)
function M.update(key, changes, on_done)
	local endpoint, _, slug = issue_endpoint(key)
	if not endpoint then
		on_done(nil, "Invalid Gitea/Forgejo issue key")
		return nil
	end
	return service.request("PATCH", endpoint, changes or {}, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local issue = mapper.to_issue(raw, slug)
		if not issue then
			on_done(nil, "Invalid Gitea/Forgejo update issue response")
			return
		end
		on_done(issue, nil)
	end)
end

---@param issue Issue
---@param changes table
---@param on_done fun(issue: Issue|nil, err: string|nil)
function M.update_issue(issue, changes, on_done)
	local payload = vim.tbl_extend("force", {}, changes or {})
	if service.api_type() == "gitea" then
		payload.content_version = issue._raw.content_version
	end
	return M.update(issue.key, payload, on_done)
end

---@param key string
---@param state "open"|"closed"
---@param on_done fun(ok: boolean, err: string|nil)
function M.set_state(key, state, on_done)
	return M.update(key, { state = state }, function(issue, err)
		on_done(issue ~= nil, err)
	end)
end

---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
function M.delete(key, on_done)
	local endpoint = issue_endpoint(key)
	if not endpoint then
		on_done(false, "Invalid Gitea/Forgejo issue key")
		return nil
	end
	return service.request("DELETE", endpoint, nil, function(_, err)
		on_done(err == nil, err)
	end)
end

---@param key string
---@param pinned boolean
---@param on_done fun(ok: boolean, err: string|nil)
function M.set_pinned(key, pinned, on_done)
	local endpoint = issue_endpoint(key)
	if not endpoint then
		on_done(false, "Invalid Gitea/Forgejo issue key")
		return nil
	end
	return service.request(pinned and "POST" or "DELETE", endpoint .. "/pin", nil, function(_, err)
		on_done(err == nil, err)
	end)
end

---@return boolean
function M.supports_locking()
	return service.api_type() == "gitea"
end

---@param key string
---@param locked boolean
---@param reason string|nil
---@param on_done fun(ok: boolean, err: string|nil)
function M.set_locked(key, locked, reason, on_done)
	if not M.supports_locking() then
		on_done(false, "Forgejo does not expose issue locking through its REST API")
		return nil
	end
	local endpoint = issue_endpoint(key)
	if not endpoint then
		on_done(false, "Invalid Gitea issue key")
		return nil
	end
	local body
	if locked then
		reason = vim.trim(tostring(reason or ""))
		body = reason ~= "" and { lock_reason = reason } or {}
	end
	return service.request(locked and "PUT" or "DELETE", endpoint .. "/lock", body, function(_, err)
		on_done(err == nil, err)
	end)
end

---@param key string
---@param assignees string[]
---@param on_done fun(ok: boolean, err: string|nil)
function M.update_assignees(key, assignees, on_done)
	return M.update(key, { assignees = assignees or {} }, function(issue, err)
		on_done(issue ~= nil, err)
	end)
end

---@param key string
---@param milestone integer|nil
---@param on_done fun(ok: boolean, err: string|nil)
function M.update_milestone(key, milestone, on_done)
	return M.update(key, { milestone = milestone or 0 }, function(issue, err)
		on_done(issue ~= nil, err)
	end)
end

---@param slug string
---@param on_done fun(labels: table[]|nil, err: string|nil)
function M.list_labels(slug, on_done)
	local base = repo_endpoint(slug)
	if not base then
		on_done(nil, "Invalid Gitea/Forgejo repository")
		return nil
	end
	return pagination.fetch_all(
		base .. "/labels",
		nil,
		{ invalid_response = "Invalid Gitea/Forgejo labels response" },
		function(raw, err)
			if err then
				on_done(nil, err)
				return
			end
			local labels = {}
			for _, value in ipairs(raw) do
				local label = map_label(value)
				if not label then
					on_done(nil, "Invalid Gitea/Forgejo label response")
					return
				end
				table.insert(labels, label)
			end
			on_done(labels, nil)
		end
	)
end

---@param slug string
---@param on_done fun(users: IssueUser[]|nil, err: string|nil)
function M.list_assignees(slug, on_done)
	local base = repo_endpoint(slug)
	if not base then
		on_done(nil, "Invalid Gitea/Forgejo repository")
		return nil
	end
	return service.request("GET", base .. "/assignees", nil, function(raw, err)
		local values, list_err = expect_list(raw, "assignees")
		if err or list_err then
			on_done(nil, err or list_err)
			return
		end
		local users = {}
		for _, value in ipairs(values or {}) do
			local user = mapper.to_user(value)
			if not user then
				on_done(nil, "Invalid Gitea/Forgejo assignee response")
				return
			end
			table.insert(users, user)
		end
		on_done(users, nil)
	end)
end

---@param slug string
---@param on_done fun(milestones: table[]|nil, err: string|nil)
function M.list_milestones(slug, on_done)
	local base = repo_endpoint(slug)
	if not base then
		on_done(nil, "Invalid Gitea/Forgejo repository")
		return nil
	end
	return pagination.fetch_all(
		base .. "/milestones",
		{ state = "open" },
		{ invalid_response = "Invalid Gitea/Forgejo milestones response" },
		function(raw, err)
			if err then
				on_done(nil, err)
				return
			end
			local milestones = {}
			for _, value in ipairs(raw) do
				local milestone = map_milestone(value)
				if not milestone then
					on_done(nil, "Invalid Gitea/Forgejo milestone response")
					return
				end
				table.insert(milestones, milestone)
			end
			on_done(milestones, nil)
		end
	)
end

---@param key string
---@param labels (integer|string)[]
---@param on_done fun(ok: boolean, err: string|nil)
function M.update_labels(key, labels, on_done)
	local endpoint = issue_endpoint(key)
	if not endpoint then
		on_done(false, "Invalid Gitea/Forgejo issue key")
		return nil
	end
	return service.request("PUT", endpoint .. "/labels", { labels = labels or {} }, function(raw, err)
		local _, list_err = expect_list(raw, "issue labels")
		on_done(err == nil and list_err == nil, err or list_err)
	end)
end

---@param key string
---@param on_done fun(subscribed: boolean|nil, err: string|nil)
function M.check_subscription(key, on_done)
	local endpoint = issue_endpoint(key)
	if not endpoint then
		on_done(nil, "Invalid Gitea/Forgejo issue key")
		return nil
	end
	return service.request("GET", endpoint .. "/subscriptions/check", nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		if type(raw.subscribed) ~= "boolean" then
			on_done(nil, "Invalid Gitea/Forgejo subscription response")
			return
		end
		on_done(raw.subscribed, nil)
	end)
end

---@param key string
---@param login string
---@param subscribe boolean
---@param on_done fun(ok: boolean, err: string|nil)
function M.set_subscription(key, login, subscribe, on_done)
	local endpoint = issue_endpoint(key)
	if not endpoint or vim.trim(tostring(login or "")) == "" then
		on_done(false, not endpoint and "Invalid Gitea/Forgejo issue key" or "Missing user login")
		return nil
	end
	local path = endpoint .. "/subscriptions/" .. service.url_encode(login)
	return service.request(subscribe and "PUT" or "DELETE", path, nil, function(_, err)
		on_done(err == nil, err)
	end)
end

return M
