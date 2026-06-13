local M = {}

local cli = require("atlas.issues.providers.gitea.api.cli")
local mapper = require("atlas.issues.providers.gitea.api.mapper")

---@param slug string
---@param state string
---@param user_param string|nil  e.g. "assignee=login" or "created_by=login"
---@param limit integer
---@param opts { force_load?: boolean }
---@param on_done fun(issues: Issue[], err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_by_slug(slug, state, user_param, limit, opts, on_done)
	local endpoint = string.format("/repos/%s/issues?type=issues&state=%s&limit=%d&page=1", slug, state, limit)
	if user_param and user_param ~= "" then
		endpoint = endpoint .. "&" .. user_param
	end
	local cache_key = string.format("gitea_issues:list:%s:%s:%s", slug, state, user_param or "all")

	if not opts.force_load then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.get(endpoint, function(result, err)
		if err then
			on_done({}, err)
			return
		end
		local issues = mapper.to_issues_list(type(result) == "table" and result or {}, slug)
		cli.set_cache(cache_key, issues)
		on_done(issues, nil)
	end, { action = "Gitea list issues", endpoint = endpoint })
end

---@param view AtlasGiteaIssuesViewConfig
---@param opts { force_load?: boolean, max_results?: number }|nil
---@param on_done fun(issues: Issue[], err: string|nil)
---@return { cancel: fun() }|nil
function M.list_issues(view, opts, on_done)
	opts = opts or {}
	local limit = math.max(1, tonumber(opts.max_results) or 50)
	local filter = type(view.filter) == "table" and view.filter or {}
	local state = tostring(filter.state or "open")
	local slug = tostring(view.repo or "")

	-- Auto-detect slug from git remote when not explicitly configured
	if slug == "" then
		local git = require("atlas.core.git")
		local root = git.repo_root()
		if root then
			local url = git.remote_url(root)
			if url then
				local info = git.parse_remote_url(url)
				if info then
					slug = info.slug
				end
			end
		end
	end

	if slug == "" then
		vim.schedule(function()
			on_done({}, 'Cannot detect repository. Open a file inside a git repo, or set repo = "owner/repo" in view config.')
		end)
		return nil
	end

	-- assigned/created/mentioned need the current user's login → fetch user first
	local needs_user = filter.assigned or filter.created or filter.mentioned
	if needs_user then
		return require("atlas.issues.providers.gitea.api.users").get_user(function(user, err)
			local login = (not err and user) and tostring(user.account_id or "") or ""
			local user_param = nil
			if login ~= "" then
				if filter.assigned then
					user_param = "assignee=" .. login
				elseif filter.created then
					user_param = "created_by=" .. login
				elseif filter.mentioned then
					user_param = "mentioned_by=" .. login
				end
			end
			fetch_by_slug(slug, state, user_param, limit, opts, function(issues, fetch_err)
				-- Forgejo may ignore assignee filter for admins — postfilter client-side
				if not fetch_err and filter.assigned and login ~= "" then
					local filtered = {}
					for _, issue in ipairs(issues) do
						local a = type(issue.assignee) == "table" and issue.assignee or nil
						if a and tostring(a.account_id or "") == login then
							table.insert(filtered, issue)
						end
					end
					on_done(filtered, nil)
				else
					on_done(issues, fetch_err)
				end
			end)
		end)
	end

	return fetch_by_slug(slug, state, nil, limit, opts, on_done)
end

---@param key string
---@param opts { force_load?: boolean }|nil
---@param on_done fun(issue: Issue|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_issue(key, opts, on_done)
	opts = opts or {}
	local slug, number = mapper.parse_key(key)
	if slug == "" or number == nil then
		vim.schedule(function()
			on_done(nil, "Invalid issue key: " .. tostring(key))
		end)
		return nil
	end

	local cache_key = string.format("gitea_issues:get:%s#%d", slug, number)
	if not opts.force_load then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/repos/%s/issues/%d", slug, number)
	return cli.get(endpoint, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		local issue = mapper.to_issue(result, slug)
		if issue then
			cli.set_mem(cache_key, issue)
		end
		on_done(issue, nil)
	end, {
		action = "Gitea get issue",
		slug = slug,
		number = number,
	})
end

---@param key string
---@param state "open"|"closed"
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_state(key, state, on_done)
	local slug, number = mapper.parse_key(key)
	if slug == "" or number == nil then
		vim.schedule(function()
			on_done(false, "Invalid issue key")
		end)
		return nil
	end

	local endpoint = string.format("/repos/%s/issues/%d", slug, number)
	local body = vim.json.encode({ state = state })
	return cli.api("PATCH", endpoint, body, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		cli.delete_cache(string.format("gitea_issues:get:%s#%d", slug, number))
		cli.delete_mem(string.format("gitea_issues:get:%s#%d", slug, number))
		on_done(true, nil)
	end, {
		action = "Gitea set issue state",
		slug = slug,
		number = number,
		state = state,
	})
end

---@param slug string
---@param on_done fun(labels: { name: string, color: string|nil }[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_labels(slug, on_done)
	if type(slug) ~= "string" or slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	local endpoint = string.format("/repos/%s/labels?limit=50", slug)
	return cli.get(endpoint, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local list = {}
		if type(result) == "table" then
			for _, raw in ipairs(result) do
				if type(raw) == "table" and type(raw.name) == "string" then
					table.insert(list, {
						name = raw.name,
						color = type(raw.color) == "string" and raw.color or nil,
						id = raw.id,
					})
				end
			end
		end
		on_done(list, nil)
	end, {
		action = "Gitea fetch repo labels",
		slug = slug,
	})
end

---@param slug string
---@param on_done fun(milestones: { id: integer, title: string }[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_milestones(slug, on_done)
	if type(slug) ~= "string" or slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	local endpoint = string.format("/repos/%s/milestones?state=open&limit=50", slug)
	return cli.get(endpoint, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local list = {}
		if type(result) == "table" then
			for _, raw in ipairs(result) do
				if type(raw) == "table" and type(raw.title) == "string" then
					table.insert(list, {
						id = raw.id,
						title = raw.title,
					})
				end
			end
		end
		on_done(list, nil)
	end, {
		action = "Gitea fetch repo milestones",
		slug = slug,
	})
end

---@class GiteaCreateIssueOpts
---@field repo_slug string
---@field title string
---@field body string|nil
---@field labels integer[]|nil  label IDs
---@field assignees string[]|nil  logins
---@field milestone integer|nil

---@param opts GiteaCreateIssueOpts
---@param on_done fun(result: { number: integer|nil, url: string|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_issue(opts, on_done)
	local slug = tostring(opts.repo_slug or "")
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	local title = tostring(opts.title or "")
	if vim.trim(title) == "" then
		vim.schedule(function()
			on_done(nil, "Title is required")
		end)
		return nil
	end

	local payload = { title = title, body = tostring(opts.body or "") }
	if type(opts.assignees) == "table" and #opts.assignees > 0 then
		payload.assignees = opts.assignees
	end
	if type(opts.labels) == "table" and #opts.labels > 0 then
		payload.labels = opts.labels
	end
	if type(opts.milestone) == "number" then
		payload.milestone = opts.milestone
	end

	local endpoint = string.format("/repos/%s/issues", slug)
	local body = vim.json.encode(payload)

	return cli.api("POST", endpoint, body, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local number = nil
		local url = nil
		if type(result) == "table" then
			number = tonumber(result.number)
			url = type(result.html_url) == "string" and result.html_url or nil
		end
		on_done({ number = number, url = url }, nil)
	end, {
		action = "Gitea create issue",
		slug = slug,
	})
end

---@param key string
---@param assignees string[]  full list of login names
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_assignees(key, assignees, on_done)
	local slug, number = mapper.parse_key(key)
	if slug == "" or number == nil then
		vim.schedule(function()
			on_done(false, "Invalid issue key")
		end)
		return nil
	end

	local endpoint = string.format("/repos/%s/issues/%d", slug, number)
	local body = vim.json.encode({ assignees = assignees })
	return cli.api("PATCH", endpoint, body, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		cli.delete_mem(string.format("gitea_issues:get:%s#%d", slug, number))
		on_done(true, nil)
	end, {
		action = "Gitea update assignees",
		slug = slug,
		number = number,
	})
end

return M
