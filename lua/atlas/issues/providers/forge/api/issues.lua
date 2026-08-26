local json = require("atlas.core.json")
local request_scope = require("atlas.core.requests")

local M = {}

---@class ForgeIssueCreateParams
---@field repo_slug string
---@field title string
---@field body string|nil
---@field labels integer[]|nil
---@field assignees string[]|nil
---@field milestone integer|nil
---@field due_date string|nil

---@class ForgeIssueCreateResult
---@field number integer
---@field key string
---@field url string|nil
---@field issue GiteaIssue|ForgejoIssue

---@class ForgeIssuePatch
---@field title string|nil
---@field body string|nil
---@field state "open"|"closed"|nil
---@field assignees string[]|nil
---@field milestone integer|nil
---@field due_date string|nil
---@field unset_due_date boolean|nil
---@field content_version integer|nil

---@class ForgeIssuesApi
---@field fetch_user fun(on_done: fun(user: IssueUser|nil, err: string|nil)): ForgeRequestHandle|nil
---@field list fun(view: AtlasGiteaIssuesViewConfig|AtlasForgejoIssuesViewConfig, opts: IssuesFetchOpts, on_done: fun(issues: Issue[]|nil, next_page_token: string|nil, is_last: boolean, err: string|nil)): ForgeRequestHandle|AtlasRequestScope|nil
---@field get fun(ref: GiteaIssue|ForgejoIssue|IssueRef|string, opts: IssuesFetchOpts|nil, on_done: fun(details: GiteaIssueDetails|ForgejoIssueDetails|nil, err: string|nil)): ForgeRequestHandle|nil
---@field fetch_by_refs fun(refs: IssueRef[], opts: IssuesFetchOpts|nil, on_done: fun(issues: Issue[], err: string|nil)): AtlasRequestScope|nil
---@field create fun(opts: ForgeIssueCreateParams, on_done: fun(result: ForgeIssueCreateResult|nil, err: string|nil)): ForgeRequestHandle|nil
---@field update_issue fun(issue: GiteaIssue|ForgejoIssue, changes: ForgeIssuePatch, on_done: fun(issue: GiteaIssue|ForgejoIssue|nil, err: string|nil)): ForgeRequestHandle|nil
---@field set_state fun(issue: GiteaIssue|ForgejoIssue, state: "open"|"closed", on_done: fun(ok: boolean, err: string|nil)): ForgeRequestHandle|nil
---@field delete fun(issue: GiteaIssue|ForgejoIssue, on_done: fun(ok: boolean, err: string|nil)): ForgeRequestHandle|nil
---@field set_pinned fun(issue: GiteaIssue|ForgejoIssue, pinned: boolean, on_done: fun(ok: boolean, err: string|nil)): ForgeRequestHandle|nil
---@field set_locked? fun(issue: GiteaIssue, locked: boolean, reason: string|nil, on_done: fun(ok: boolean, err: string|nil)): ForgeRequestHandle|nil
---@field update_assignees fun(issue: GiteaIssue|ForgejoIssue, assignees: string[], on_done: fun(ok: boolean, err: string|nil)): ForgeRequestHandle|nil
---@field update_milestone fun(issue: GiteaIssue|ForgejoIssue, milestone: integer|nil, on_done: fun(ok: boolean, err: string|nil)): ForgeRequestHandle|nil
---@field list_labels fun(slug: string, on_done: fun(labels: (GiteaIssueLabel|ForgejoIssueLabel)[]|nil, err: string|nil)): AtlasRequestScope|nil
---@field list_assignees fun(slug: string, on_done: fun(users: IssueUser[]|nil, err: string|nil)): ForgeRequestHandle|nil
---@field list_milestones fun(slug: string, on_done: fun(milestones: (GiteaIssueMilestone|ForgejoIssueMilestone)[]|nil, err: string|nil)): AtlasRequestScope|nil
---@field update_labels fun(issue: GiteaIssue|ForgejoIssue, labels: (integer|string)[], on_done: fun(ok: boolean, err: string|nil)): ForgeRequestHandle|nil
---@field check_subscription fun(issue: GiteaIssue|ForgejoIssue, on_done: fun(subscribed: boolean|nil, err: string|nil)): ForgeRequestHandle|nil
---@field set_subscription fun(issue: GiteaIssue|ForgejoIssue, login: string, subscribe: boolean, on_done: fun(ok: boolean, err: string|nil)): ForgeRequestHandle|nil

---@param service ForgeService
---@param mapper ForgeIssueMapper
---@return ForgeIssuesApi
function M.new(service, mapper)
	local provider_id = service.id
	local provider_name = service.name
	---@type ForgeIssuesApi
	local api = {}

	local function cache_scope()
		return string.format("%s:issues:%s", provider_id, service.base_url())
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

	---@param value GiteaIssue|ForgejoIssue|IssueRef|string
	---@return string|nil, integer|nil, string|nil, string|nil
	local function issue_endpoint(value)
		local repo_full_name, number
		if type(value) == "table" then
			local issue = value --[[@as GiteaIssue|ForgejoIssue]]
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
	function api.fetch_user(on_done)
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

	---@param view AtlasGiteaIssuesViewConfig|AtlasForgejoIssuesViewConfig
	---@param opts IssuesFetchOpts
	---@param on_done fun(issues: Issue[]|nil, next_page_token: string|nil, is_last: boolean, err: string|nil)
	function api.list(view, opts, on_done)
		local page = math.max(1, tonumber(opts.next_page_token) or 1)
		local limit = math.max(1, math.min(50, opts.max_results or 50))
		local scope = view.scope or ""
		local has_scoped_filter = scope == "assigned" or scope == "created" or scope == "mentioned"
		if scope ~= "" and scope ~= "all" and not has_scoped_filter then
			on_done(nil, nil, true, "Invalid " .. provider_name .. " issue scope: " .. scope)
			return nil
		end
		local repo = vim.trim(view.repo or "")
		local base = repo_endpoint(repo)
		if repo ~= "" and not base then
			on_done(nil, nil, true, "Invalid " .. provider_name .. " repository")
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
			requests.run(api.fetch_user, function(user, err)
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

	---@param ref GiteaIssue|ForgejoIssue|IssueRef|string
	---@param opts IssuesFetchOpts|nil
	---@param on_done fun(details: GiteaIssueDetails|ForgejoIssueDetails|nil, err: string|nil)
	---@return { cancel: fun() }|nil
	function api.get(ref, opts, on_done)
		opts = opts or {}
		local endpoint, _, repo_full_name, key = issue_endpoint(ref)
		if not endpoint then
			on_done(nil, "Invalid " .. provider_name .. " issue key")
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
		return service.request("GET", endpoint, nil, function(raw, err)
			if err then
				on_done(nil, err)
				return
			end
			local details = mapper.to_issue_details(raw, repo_full_name)
			if not details then
				on_done(nil, "The requested number is not an issue")
				return
			end
			service.set_memory_cache(cache_key, details)
			on_done(details, nil)
		end)
	end

	---@param refs IssueRef[]
	---@param _opts IssuesFetchOpts|nil
	---@param on_done fun(issues: Issue[], err: string|nil)
	---@return { cancel: fun() }|nil
	function api.fetch_by_refs(refs, _opts, on_done)
		if #refs == 0 then
			on_done({}, nil)
			return nil
		end

		local starts = {}
		for index, ref in ipairs(refs) do
			local endpoint, _, repo_full_name = issue_endpoint(ref)
			if not endpoint then
				on_done({}, "Invalid " .. provider_name .. " issue key: " .. tostring(ref.key))
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

	---@param opts ForgeIssueCreateParams
	---@param on_done fun(result: ForgeIssueCreateResult|nil, err: string|nil)
	function api.create(opts, on_done)
		local slug = vim.trim(opts.repo_slug)
		local base = repo_endpoint(slug)
		local title = vim.trim(opts.title)
		if not base or title == "" then
			on_done(nil, not base and ("Invalid " .. provider_name .. " repository") or "Title is required")
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
			---@cast issue GiteaIssue|ForgejoIssue
			clear_issue_cache(nil)
			on_done({ number = issue.number, key = issue.key, url = issue.url, issue = issue }, nil)
		end)
	end

	---@param issue GiteaIssue|ForgejoIssue
	---@param changes ForgeIssuePatch
	---@param on_done fun(issue: GiteaIssue|ForgejoIssue|nil, err: string|nil)
	local function update(issue, changes, on_done)
		local endpoint, _, repo_full_name, key = issue_endpoint(issue)
		if not endpoint then
			on_done(nil, "Invalid " .. provider_name .. " issue key")
			return nil
		end
		return service.request("PATCH", endpoint, changes, function(raw, err)
			if err then
				on_done(nil, err)
				return
			end
			local updated = mapper.to_issue(raw, repo_full_name)
			if not updated then
				on_done(nil, "The updated number is not an issue")
				return
			end
			clear_issue_cache(key)
			on_done(updated, nil)
		end)
	end

	---@param issue GiteaIssue|ForgejoIssue
	---@param changes ForgeIssuePatch
	---@param on_done fun(issue: GiteaIssue|ForgejoIssue|nil, err: string|nil)
	function api.update_issue(issue, changes, on_done)
		local payload = changes
		if provider_id == "gitea" then
			---@cast issue GiteaIssue
			payload = vim.tbl_extend("force", {}, changes)
			payload.content_version = issue.content_version
		end
		return update(issue, payload, on_done)
	end

	---@param issue GiteaIssue|ForgejoIssue
	---@param state "open"|"closed"
	---@param on_done fun(ok: boolean, err: string|nil)
	function api.set_state(issue, state, on_done)
		return update(issue, { state = state }, function(updated, err)
			on_done(updated ~= nil, err)
		end)
	end

	---@param issue GiteaIssue|ForgejoIssue
	---@param on_done fun(ok: boolean, err: string|nil)
	function api.delete(issue, on_done)
		local endpoint, _, _, key = issue_endpoint(issue)
		if not endpoint then
			on_done(false, "Invalid " .. provider_name .. " issue key")
			return nil
		end
		return service.request("DELETE", endpoint, nil, function(_, err)
			if not err then
				clear_issue_cache(key)
			end
			on_done(err == nil, err)
		end)
	end

	---@param issue GiteaIssue|ForgejoIssue
	---@param pinned boolean
	---@param on_done fun(ok: boolean, err: string|nil)
	function api.set_pinned(issue, pinned, on_done)
		local endpoint, _, _, key = issue_endpoint(issue)
		if not endpoint then
			on_done(false, "Invalid " .. provider_name .. " issue key")
			return nil
		end
		return service.request(pinned and "POST" or "DELETE", endpoint .. "/pin", nil, function(_, err)
			if not err then
				clear_issue_cache(key)
			end
			on_done(err == nil, err)
		end)
	end

	if provider_id == "gitea" then
		---@param issue GiteaIssue
		---@param locked boolean
		---@param reason string|nil
		---@param on_done fun(ok: boolean, err: string|nil)
		function api.set_locked(issue, locked, reason, on_done)
			local endpoint, _, _, key = issue_endpoint(issue)
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
				if not err then
					clear_issue_cache(key)
				end
				on_done(err == nil, err)
			end)
		end
	end

	---@param issue GiteaIssue|ForgejoIssue
	---@param assignees string[]
	---@param on_done fun(ok: boolean, err: string|nil)
	function api.update_assignees(issue, assignees, on_done)
		return update(issue, { assignees = assignees }, function(updated, err)
			on_done(updated ~= nil, err)
		end)
	end

	---@param issue GiteaIssue|ForgejoIssue
	---@param milestone integer|nil
	---@param on_done fun(ok: boolean, err: string|nil)
	function api.update_milestone(issue, milestone, on_done)
		return update(issue, { milestone = milestone or 0 }, function(updated, err)
			on_done(updated ~= nil, err)
		end)
	end

	---@param slug string
	---@param on_done fun(labels: (GiteaIssueLabel|ForgejoIssueLabel)[]|nil, err: string|nil)
	function api.list_labels(slug, on_done)
		local base = repo_endpoint(slug)
		if not base then
			on_done(nil, "Invalid " .. provider_name .. " repository")
			return nil
		end
		return service.fetch_all(base .. "/labels", nil, {}, function(raw, err)
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
	function api.list_assignees(slug, on_done)
		local base = repo_endpoint(slug)
		if not base then
			on_done(nil, "Invalid " .. provider_name .. " repository")
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
	---@param on_done fun(milestones: (GiteaIssueMilestone|ForgejoIssueMilestone)[]|nil, err: string|nil)
	function api.list_milestones(slug, on_done)
		local base = repo_endpoint(slug)
		if not base then
			on_done(nil, "Invalid " .. provider_name .. " repository")
			return nil
		end
		return service.fetch_all(base .. "/milestones", { state = "open" }, {}, function(raw, err)
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

	---@param issue GiteaIssue|ForgejoIssue
	---@param labels (integer|string)[]
	---@param on_done fun(ok: boolean, err: string|nil)
	function api.update_labels(issue, labels, on_done)
		local endpoint, _, _, key = issue_endpoint(issue)
		if not endpoint then
			on_done(false, "Invalid " .. provider_name .. " issue key")
			return nil
		end
		return service.request("PUT", endpoint .. "/labels", { labels = labels }, function(_, err)
			if not err then
				clear_issue_cache(key)
			end
			on_done(err == nil, err)
		end)
	end

	---@param issue GiteaIssue|ForgejoIssue
	---@param on_done fun(subscribed: boolean|nil, err: string|nil)
	function api.check_subscription(issue, on_done)
		local endpoint = issue_endpoint(issue)
		if not endpoint then
			on_done(nil, "Invalid " .. provider_name .. " issue key")
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

	---@param issue GiteaIssue|ForgejoIssue
	---@param login string
	---@param subscribe boolean
	---@param on_done fun(ok: boolean, err: string|nil)
	function api.set_subscription(issue, login, subscribe, on_done)
		local endpoint = issue_endpoint(issue)
		if not endpoint or vim.trim(login) == "" then
			local invalid = "Invalid " .. provider_name .. " issue key"
			on_done(false, not endpoint and invalid or "Missing user login")
			return nil
		end
		local path = endpoint .. "/subscriptions/" .. service.url_encode(login)
		return service.request(subscribe and "PUT" or "DELETE", path, nil, function(_, err)
			if not err then
				service.clear_cache(cache_scope() .. ":list:")
			end
			on_done(err == nil, err)
		end)
	end

	return api
end

return M
