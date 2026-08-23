local service = require("atlas.providers.gitea.client").issues
local pagination = require("atlas.providers.gitea.pagination").issues
local json = require("atlas.core.json")
local request_scope = require("atlas.core.requests")
local mapper = require("atlas.issues.providers.gitea.api.mapper")

local M = {}

---@param slug string|nil
---@return string|nil
local function repo_endpoint(slug)
	local owner, repo = vim.trim(slug or ""):match("^([^/%s]+)/([^/%s]+)$")
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

---@param raw table[]
---@param scoped_slug string|nil
---@return Issue[]
local function map_issues(raw, scoped_slug)
	local issues = {}
	for _, value in ipairs(raw) do
		if json.nilify(value.pull_request) == nil then
			table.insert(issues, mapper.to_issue(value, scoped_slug))
		end
	end
	return issues
end

---@param raw table
---@return table
local function map_label(raw)
	return {
		id = raw.id,
		name = raw.name,
		color = raw.color,
	}
end

---@param raw table
---@return table
local function map_milestone(raw)
	return { id = raw.id, title = raw.title }
end

---@param on_done fun(user: IssueUser|nil, err: string|nil)
function M.fetch_user(on_done)
	return service.request("GET", "/user", nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(mapper.to_user(raw), nil)
	end)
end

---@param view AtlasGiteaIssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[]|nil, next_page_token: string|nil, is_last: boolean, err: string|nil)
function M.list(view, opts, on_done)
	local page = math.max(1, tonumber(opts.next_page_token) or 1)
	local limit = math.max(1, math.min(50, opts.max_results or 50))
	local scope = view.scope or ""
	local has_scoped_filter = scope == "assigned" or scope == "created" or scope == "mentioned"
	if scope ~= "" and scope ~= "all" and scope ~= "assigned" and scope ~= "created" and scope ~= "mentioned" then
		on_done(nil, nil, true, "Invalid Gitea issue scope: " .. scope)
		return nil
	end
	local repo = vim.trim(view.repo or "")
	local base = repo_endpoint(repo)
	if repo ~= "" and not base then
		on_done(nil, nil, true, "Invalid Gitea repository")
		return nil
	end
	local params = {}
	for key, value in pairs(view.extra_params or {}) do
		params[key] = value
	end
	local endpoint = base and (base .. "/issues") or "/repos/issues/search"
	params.state = view.state or "open"
	params.type = "issues"
	params.page = page
	params.limit = limit
	params.q = view.search
	params.labels = view.labels

	if not base then
		params.assigned = scope == "assigned" or nil
		params.created = scope == "created" or nil
		params.mentioned = scope == "mentioned" or nil
	end

	local function fetch(done)
		return service.request("GET", endpoint .. service.query(params), nil, done)
	end
	local function finish(raw, err)
		if err then
			on_done(nil, nil, true, err)
			return
		end
		local issues = map_issues(raw, base and repo or nil)
		local has_next = #raw > 0
		on_done(issues, has_next and tostring(page + 1) or nil, not has_next, nil)
	end

	if base and has_scoped_filter then
		local requests = request_scope.new()
		requests.run(M.fetch_user, function(user, err)
			if err then
				on_done(nil, nil, true, err)
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
---@param on_done fun(issue: IssueDetails|nil, err: string|nil)
function M.get(key, _, on_done)
	local endpoint, _, slug = issue_endpoint(key)
	if not endpoint then
		on_done(nil, "Invalid Gitea issue key: " .. key)
		return nil
	end
	return service.request("GET", endpoint, nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local issue = mapper.to_issue_details(raw, slug)
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
	local slug = vim.trim(opts.repo_slug)
	local base = repo_endpoint(slug)
	local title = vim.trim(opts.title)
	if not base or title == "" then
		on_done(nil, not base and "Invalid Gitea repository" or "Title is required")
		return nil
	end
	return service.request("POST", base .. "/issues", {
		title = title,
		body = opts.body or "",
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
		on_done({ number = issue._raw.number, key = issue.key, url = issue.url, issue = issue }, nil)
	end)
end

---@param key string
---@param changes table
---@param on_done fun(issue: Issue|nil, err: string|nil)
function M.update(key, changes, on_done)
	local endpoint, _, slug = issue_endpoint(key)
	if not endpoint then
		on_done(nil, "Invalid Gitea issue key")
		return nil
	end
	return service.request("PATCH", endpoint, changes, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local issue = mapper.to_issue(raw, slug)
		on_done(issue, nil)
	end)
end

---@param issue Issue
---@param changes table
---@param on_done fun(issue: Issue|nil, err: string|nil)
function M.update_issue(issue, changes, on_done)
	local payload = vim.tbl_extend("force", {}, changes)
	payload.content_version = issue._raw.content_version
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
		on_done(false, "Invalid Gitea issue key")
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
		on_done(false, "Invalid Gitea issue key")
		return nil
	end
	return service.request(pinned and "POST" or "DELETE", endpoint .. "/pin", nil, function(_, err)
		on_done(err == nil, err)
	end)
end

---@param key string
---@param locked boolean
---@param reason string|nil
---@param on_done fun(ok: boolean, err: string|nil)
function M.set_locked(key, locked, reason, on_done)
	local endpoint = issue_endpoint(key)
	if not endpoint then
		on_done(false, "Invalid Gitea issue key")
		return nil
	end
	local body
	if locked then
		reason = vim.trim(reason or "")
		body = reason ~= "" and { lock_reason = reason } or vim.empty_dict()
	end
	return service.request(locked and "PUT" or "DELETE", endpoint .. "/lock", body, function(_, err)
		on_done(err == nil, err)
	end)
end

---@param key string
---@param assignees string[]
---@param on_done fun(ok: boolean, err: string|nil)
function M.update_assignees(key, assignees, on_done)
	return M.update(key, { assignees = assignees }, function(issue, err)
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
		on_done(nil, "Invalid Gitea repository")
		return nil
	end
	return pagination.fetch_all(base .. "/labels", nil, {}, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local labels = {}
		for _, value in ipairs(raw) do
			table.insert(labels, map_label(value))
		end
		on_done(labels, nil)
	end)
end

---@param slug string
---@param on_done fun(users: IssueUser[]|nil, err: string|nil)
function M.list_assignees(slug, on_done)
	local base = repo_endpoint(slug)
	if not base then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end
	return service.request("GET", base .. "/assignees", nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local users = {}
		for _, value in ipairs(raw) do
			table.insert(users, mapper.to_user(value))
		end
		on_done(users, nil)
	end)
end

---@param slug string
---@param on_done fun(milestones: table[]|nil, err: string|nil)
function M.list_milestones(slug, on_done)
	local base = repo_endpoint(slug)
	if not base then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end
	return pagination.fetch_all(base .. "/milestones", { state = "open" }, {}, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local milestones = {}
		for _, value in ipairs(raw) do
			table.insert(milestones, map_milestone(value))
		end
		on_done(milestones, nil)
	end)
end

---@param key string
---@param labels (integer|string)[]
---@param on_done fun(ok: boolean, err: string|nil)
function M.update_labels(key, labels, on_done)
	local endpoint = issue_endpoint(key)
	if not endpoint then
		on_done(false, "Invalid Gitea issue key")
		return nil
	end
	return service.request("PUT", endpoint .. "/labels", { labels = labels }, function(_, err)
		on_done(err == nil, err)
	end)
end

---@param key string
---@param on_done fun(subscribed: boolean|nil, err: string|nil)
function M.check_subscription(key, on_done)
	local endpoint = issue_endpoint(key)
	if not endpoint then
		on_done(nil, "Invalid Gitea issue key")
		return nil
	end
	return service.request("GET", endpoint .. "/subscriptions/check", nil, function(raw, err)
		if err then
			on_done(nil, err)
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
	if not endpoint or vim.trim(login) == "" then
		on_done(false, not endpoint and "Invalid Gitea issue key" or "Missing user login")
		return nil
	end
	local path = endpoint .. "/subscriptions/" .. service.url_encode(login)
	return service.request(subscribe and "PUT" or "DELETE", path, nil, function(_, err)
		on_done(err == nil, err)
	end)
end

return M
