local json = require("atlas.core.json")
local request_scope = require("atlas.core.requests")
local mapper = require("atlas.issues.providers.forgejo.api.mapper")

local M = {}
local service = require("atlas.providers.forgejo.client")
local pagination = require("atlas.providers.forgejo.pagination")

local function cache_scope()
	return string.format("forgejo:issues:%s", service.base_url())
end

local function detail_cache_key(key)
	return cache_scope() .. ":detail:" .. key
end

local function clear_issue_cache(key)
	service.clear_cache(cache_scope() .. ":list:")
	if key then
		service.delete_memory_cache(detail_cache_key(key))
	end
end

---@param slug string|nil
---@return string|nil
local function repo_endpoint(slug)
	local owner, repo = vim.trim(slug or ""):match("^([^/%s]+)/([^/%s]+)$")
	if not owner then
		return nil
	end
	return string.format("/repos/%s/%s", service.url_encode(owner), service.url_encode(repo))
end

---@param value ForgejoIssue|IssueRef|string
---@return string|nil, integer|nil, string|nil, string|nil
local function issue_endpoint(value)
	local repo_full_name, number
	if type(value) == "table" then
		local issue = value --[[@as ForgejoIssue]]
		repo_full_name, number = issue.repo_full_name, issue.number
		if not repo_full_name or not number then
			repo_full_name, number = mapper.parse_key(value.key)
		end
	else
		repo_full_name, number = mapper.parse_key(value)
	end
	local base = repo_endpoint(repo_full_name)
	if not base or not number then
		return nil, nil, nil, nil
	end
	local key = string.format("%s#%d", repo_full_name, number)
	return string.format("%s/issues/%d", base, number), number, repo_full_name, key
end

---@param on_done fun(user: IssueUser|nil, err: string|nil)
function M.fetch_user(on_done)
	local cache_key = cache_scope() .. ":user"
	local cached, ok = service.get_cache(cache_key)
	if ok then
		on_done(cached, nil)
		return nil
	end
	return service.request("GET", "/user", nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local result = mapper.to_user(raw)
		if result then
			service.set_cache(cache_key, result)
		end
		on_done(result, nil)
	end)
end

---@param view AtlasForgejoIssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[]|nil, next_page_token: string|nil, is_last: boolean, err: string|nil)
function M.list(view, opts, on_done)
	local page = math.max(1, tonumber(opts.next_page_token) or 1)
	local limit = math.max(1, math.min(50, opts.max_results or 50))
	local scope = view.scope or ""
	local has_scoped_filter = scope == "assigned" or scope == "created" or scope == "mentioned"
	if scope ~= "" and scope ~= "all" and scope ~= "assigned" and scope ~= "created" and scope ~= "mentioned" then
		on_done(nil, nil, true, "Invalid Forgejo issue scope: " .. scope)
		return nil
	end
	local repo = vim.trim(view.repo or "")
	local base = repo_endpoint(repo)
	if repo ~= "" and not base then
		on_done(nil, nil, true, "Invalid Forgejo repository")
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
		local request_endpoint = endpoint .. service.query(params)
		local cache_key = cache_scope() .. ":list:" .. request_endpoint
		if not opts.force_load then
			local cached, ok = service.get_cache(cache_key)
			if ok then
				done(cached, nil)
				return nil
			end
		end
		return service.request("GET", request_endpoint, nil, function(raw, err)
			if err then
				done(nil, err)
				return
			end
			local issues = {}
			for _, value in ipairs(raw) do
				if json.nilify(value.pull_request) == nil then
					table.insert(issues, mapper.to_issue(value, base and repo or nil))
				end
			end
			local has_next = #raw == limit
			local result = {
				issues = issues,
				next_page_token = has_next and tostring(page + 1) or nil,
				is_last = not has_next,
			}
			service.set_cache(cache_key, result)
			done(result, nil)
		end)
	end
	local function finish(result, err)
		if err then
			on_done(nil, nil, true, err)
			return
		end
		on_done(result.issues, result.next_page_token, result.is_last, nil)
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

---@param ref ForgejoIssue|IssueRef|string
---@param opts IssuesFetchOpts|nil
---@param on_done fun(issue: IssueDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get(ref, opts, on_done)
	opts = opts or {}
	local endpoint, _, repo_full_name, key = issue_endpoint(ref)
	if not endpoint then
		on_done(nil, "Invalid Forgejo issue key")
		return nil
	end
	local cache_key = detail_cache_key(key)
	if not opts.force_load then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end
	local requests = request_scope.new()
	requests.all({
		details = function(done)
			return service.request("GET", endpoint, nil, done)
		end,
		subscription = function(done)
			return service.request("GET", endpoint .. "/subscriptions/check", nil, function(raw, err)
				done(raw and raw.subscribed, err)
			end)
		end,
	}, function(values, errors)
		if errors.details then
			on_done(nil, errors.details)
			return
		end
		local issue = mapper.to_issue_details(values.details, repo_full_name)
		if not issue then
			on_done(nil, "The requested number is not an issue")
			return
		end
		if errors.subscription == nil then
			issue.is_subscribed = values.subscription
		end
		service.set_memory_cache(cache_key, issue)
		on_done(issue, nil)
	end)
	return requests
end

---@param refs IssueRef[]
---@param _opts IssuesFetchOpts|nil
---@param on_done fun(issues: Issue[], err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_by_refs(refs, _opts, on_done)
	if #refs == 0 then
		on_done({}, nil)
		return nil
	end

	local starts = {}
	for index, ref in ipairs(refs) do
		local endpoint, _, repo_full_name = issue_endpoint(ref)
		if not endpoint then
			on_done({}, "Invalid Forgejo issue key: " .. tostring(ref.key))
			return nil
		end
		starts[index] = function(done)
			return service.request("GET", endpoint, nil, function(raw, err)
				done(raw and mapper.to_issue(raw, repo_full_name) or nil, err)
			end)
		end
	end

	local requests = request_scope.new()
	requests.all(starts, function(values, errors)
		local issues = {}
		for index = 1, #refs do
			if errors[index] then
				on_done({}, errors[index])
				return
			end
			if values[index] then
				table.insert(issues, values[index])
			end
		end
		on_done(issues, nil)
	end)
	return requests
end

---@param opts { repo_slug: string, title: string, body: string|nil, labels: integer[]|nil, assignees: string[]|nil, milestone: integer|nil, due_date: string|nil }
---@param on_done fun(result: table|nil, err: string|nil)
function M.create(opts, on_done)
	local slug = vim.trim(opts.repo_slug)
	local base = repo_endpoint(slug)
	local title = vim.trim(opts.title)
	if not base or title == "" then
		on_done(nil, not base and "Invalid Forgejo repository" or "Title is required")
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
		---@cast issue ForgejoIssue
		clear_issue_cache(nil)
		on_done({ number = issue.number, key = issue.key, url = issue.url, issue = issue }, nil)
	end)
end

---@param issue ForgejoIssue
---@param changes table
---@param on_done fun(issue: Issue|nil, err: string|nil)
function M.update(issue, changes, on_done)
	local endpoint, _, repo_full_name, key = issue_endpoint(issue)
	if not endpoint then
		on_done(nil, "Invalid Forgejo issue key")
		return nil
	end
	return service.request("PATCH", endpoint, changes, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local updated = mapper.to_issue_details(raw, repo_full_name)
		clear_issue_cache(key)
		on_done(updated, nil)
	end)
end

---@param issue IssueDetails
---@param changes table
---@param on_done fun(issue: Issue|nil, err: string|nil)
function M.update_issue(issue, changes, on_done)
	---@cast issue ForgejoIssueDetails
	return M.update(issue, changes, on_done)
end

---@param issue ForgejoIssue
---@param state "open"|"closed"
---@param on_done fun(ok: boolean, err: string|nil)
function M.set_state(issue, state, on_done)
	return M.update(issue, { state = state }, function(updated, err)
		on_done(updated ~= nil, err)
	end)
end

---@param issue ForgejoIssue
---@param on_done fun(ok: boolean, err: string|nil)
function M.delete(issue, on_done)
	local endpoint, _, _, key = issue_endpoint(issue)
	if not endpoint then
		on_done(false, "Invalid Forgejo issue key")
		return nil
	end
	return service.request("DELETE", endpoint, nil, function(_, err)
		if not err then
			clear_issue_cache(key)
		end
		on_done(err == nil, err)
	end)
end

---@param issue ForgejoIssue
---@param pinned boolean
---@param on_done fun(ok: boolean, err: string|nil)
function M.set_pinned(issue, pinned, on_done)
	local endpoint, _, _, key = issue_endpoint(issue)
	if not endpoint then
		on_done(false, "Invalid Forgejo issue key")
		return nil
	end
	return service.request(pinned and "POST" or "DELETE", endpoint .. "/pin", nil, function(_, err)
		if not err then
			clear_issue_cache(key)
		end
		on_done(err == nil, err)
	end)
end

---@param issue ForgejoIssue
---@param assignees string[]
---@param on_done fun(ok: boolean, err: string|nil)
function M.update_assignees(issue, assignees, on_done)
	return M.update(issue, { assignees = assignees }, function(updated, err)
		on_done(updated ~= nil, err)
	end)
end

---@param issue ForgejoIssue
---@param milestone integer|nil
---@param on_done fun(ok: boolean, err: string|nil)
function M.update_milestone(issue, milestone, on_done)
	return M.update(issue, { milestone = milestone or 0 }, function(updated, err)
		on_done(updated ~= nil, err)
	end)
end

---@param slug string
---@param on_done fun(labels: table[]|nil, err: string|nil)
function M.list_labels(slug, on_done)
	local base = repo_endpoint(slug)
	if not base then
		on_done(nil, "Invalid Forgejo repository")
		return nil
	end
	return pagination.fetch_all(base .. "/labels", nil, {}, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local labels = {}
		for _, value in ipairs(raw) do
			table.insert(labels, {
				id = value.id,
				name = value.name,
				color = value.color,
			})
		end
		on_done(labels, nil)
	end)
end

---@param slug string
---@param on_done fun(users: IssueUser[]|nil, err: string|nil)
function M.list_assignees(slug, on_done)
	local base = repo_endpoint(slug)
	if not base then
		on_done(nil, "Invalid Forgejo repository")
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
		on_done(nil, "Invalid Forgejo repository")
		return nil
	end
	return pagination.fetch_all(base .. "/milestones", { state = "open" }, {}, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local milestones = {}
		for _, value in ipairs(raw) do
			table.insert(milestones, { id = value.id, title = value.title })
		end
		on_done(milestones, nil)
	end)
end

---@param issue ForgejoIssue
---@param labels (integer|string)[]
---@param on_done fun(ok: boolean, err: string|nil)
function M.update_labels(issue, labels, on_done)
	local endpoint, _, _, key = issue_endpoint(issue)
	if not endpoint then
		on_done(false, "Invalid Forgejo issue key")
		return nil
	end
	return service.request("PUT", endpoint .. "/labels", { labels = labels }, function(_, err)
		if not err then
			clear_issue_cache(key)
		end
		on_done(err == nil, err)
	end)
end

---@param issue ForgejoIssue
---@param on_done fun(subscribed: boolean|nil, err: string|nil)
function M.check_subscription(issue, on_done)
	local endpoint = issue_endpoint(issue)
	if not endpoint then
		on_done(nil, "Invalid Forgejo issue key")
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

---@param issue ForgejoIssue
---@param login string
---@param subscribe boolean
---@param on_done fun(ok: boolean, err: string|nil)
function M.set_subscription(issue, login, subscribe, on_done)
	local endpoint, _, _, key = issue_endpoint(issue)
	if not endpoint or vim.trim(login) == "" then
		on_done(false, not endpoint and "Invalid Forgejo issue key" or "Missing user login")
		return nil
	end
	local path = endpoint .. "/subscriptions/" .. service.url_encode(login)
	return service.request(subscribe and "PUT" or "DELETE", path, nil, function(_, err)
		if not err then
			service.delete_memory_cache(detail_cache_key(key))
		end
		on_done(err == nil, err)
	end)
end

return M
