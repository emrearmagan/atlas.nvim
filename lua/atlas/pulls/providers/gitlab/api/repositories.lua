local M = {}

local request_scope = require("atlas.core.requests")
local service = require("atlas.providers.gitlab.client")
local config = require("atlas.config")
local json = require("atlas.core.json")

---@param repo PullsRepo
---@return string
local function configured_readme_path(repo)
	local repo_cfg = (((config.options or {}).pulls or {}).repo_config or {})
	local settings = repo_cfg.settings or {}
	local keys = { tostring(repo.id or ""), tostring(repo.name or "") }
	for _, key in ipairs(keys) do
		if key ~= "" then
			local entry = settings[key]
			if type(entry) == "table" and tostring(entry.readme or "") ~= "" then
				return tostring(entry.readme)
			end
		end
	end
	return "README.md"
end

---@param repo PullsRepo
---@return string
local function repo_path(repo)
	local id = tostring(repo.id or "")
	if id ~= "" then
		return id
	end
	local owner = tostring(repo.owner or "")
	local name = tostring(repo.repo_name or repo.name or "")
	if owner == "" or name == "" then
		return ""
	end
	return owner .. "/" .. name
end

---@param repo PullsRepo
---@param opts PullsFetchOpts
---@param on_done fun(details: PullsRepoDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_detail(repo, opts, on_done)
	opts = opts or {}
	local path = repo_path(repo)
	if path == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local cache_key = string.format("gitlab:repo_details:%s", path)
	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/projects/%s?statistics=true", service.url_encode(path))
	local requests = request_scope.new()
	requests.run(function(done)
		return service.request("GET", endpoint, nil, done, {
			action = "Fetch repository",
			repo = path,
		})
	end, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		result = json.safe_table(result)

		local name = json.safe_str(result.path) or tostring(repo.repo_name or repo.name or "")
		local full_path = json.safe_str(result.path_with_namespace) or path
		local owner = full_path:match("^(.-)/[^/]+$") or ""

		local statistics = json.safe_table(result.statistics)

		---@type PullsRepoDetails
		local details = {
			id = full_path,
			name = name,
			full_name = full_path,
			owner = owner,
			repo_name = name,
			html_url = json.safe_str(result.web_url) or "",
			description = json.safe_str(result.description) or "",
			size = tonumber(statistics.repository_size),
			default_branch = json.safe_str(result.default_branch) or "",
			is_private = json.safe_str(result.visibility) == "private",
			created_on = json.safe_str(result.created_at) or "",
			readme = nil,
			stars = tonumber(result.star_count) or nil,
			forks = tonumber(result.forks_count) or nil,
			watchers = nil,
		}

		local project_id = tonumber(result.id)
		local default_branch = details.default_branch or ""
		if project_id == nil or default_branch == "" then
			service.set_memory_cache(cache_key, details)
			on_done(details, nil)
			return
		end

		local readme_path = configured_readme_path(repo)
		local readme_endpoint = string.format(
			"/projects/%d/repository/files/%s/raw?ref=%s",
			project_id,
			service.url_encode(readme_path),
			service.url_encode(default_branch)
		)
		requests.run(function(done)
			return service.request_text("GET", readme_endpoint, done, {
				action = "Fetch repository README",
				repo = path,
				path = readme_path,
			})
		end, function(body, _)
			if body and body ~= "" then
				details.readme = body
			end
			service.set_memory_cache(cache_key, details)
			on_done(details, nil)
		end)
	end)
	return requests
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(branches: PullsRepoBranches|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_branches(repo, opts, on_done)
	opts = opts or {}
	local path = repo_path(repo)
	if path == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local cache_key = string.format("gitlab:branches:%s", path)
	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/projects/%s/repository/branches?per_page=100", service.url_encode(path))
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local entries = {}
		for _, branch_value in ipairs(json.safe_table(result)) do
			local branch = json.safe_table(branch_value)
			local commit = json.safe_table(branch.commit)
			table.insert(entries, {
				name = json.safe_str(branch.name) or "",
				hash = (json.safe_str(commit.short_id) or json.safe_str(commit.id) or ""):sub(1, 8),
				date = json.safe_str(commit.committed_date) or "",
				message = json.safe_str(commit.title) or "",
				author = json.safe_str(commit.author_name) or "",
			})
		end

		local branches = { entries = entries }
		service.set_memory_cache(cache_key, branches)
		on_done(branches, nil)
	end, {
		action = "Fetch repository branches",
		repo = path,
	})
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(tags: PullsRepoTags|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_tags(repo, opts, on_done)
	opts = opts or {}
	local path = repo_path(repo)
	if path == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local cache_key = string.format("gitlab:tags:%s", path)
	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/projects/%s/repository/tags?per_page=100", service.url_encode(path))
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local entries = {}
		for _, tag_value in ipairs(json.safe_table(result)) do
			local tag = json.safe_table(tag_value)
			local commit = json.safe_table(tag.commit)
			table.insert(entries, {
				name = json.safe_str(tag.name) or "",
				hash = (json.safe_str(commit.short_id) or json.safe_str(commit.id) or ""):sub(1, 8),
				date = json.safe_str(commit.committed_date) or "",
				message = json.safe_str(tag.message) or json.safe_str(commit.title) or "",
				author = json.safe_str(commit.author_name) or "",
			})
		end

		local tags = { entries = entries }
		service.set_memory_cache(cache_key, tags)
		on_done(tags, nil)
	end, {
		action = "Fetch repository tags",
		repo = path,
	})
end

---@param repo PullsRepoDetails
---@param state "open"|"closed"
---@param _opts PullsFetchOpts
---@param on_done fun(result: { entries: PullsRepoIssue[], counts: { open: integer, closed: integer }|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issues(repo, state, _opts, on_done)
	local path = repo_path(repo)
	if path == "" then
		on_done(nil, "Missing repository info")
		return nil
	end

	local project = service.url_encode(path)
	local api_state = state == "open" and "opened" or "closed"
	local requests = request_scope.new()
	requests.all({
		issues = function(done)
			local endpoint = string.format(
				"/projects/%s/issues?state=%s&per_page=50&order_by=created_at&sort=desc",
				project,
				api_state
			)
			return service.request("GET", endpoint, nil, done, {
				action = "Fetch repository issues",
				repo = path,
				state = state,
			})
		end,
		statistics = function(done)
			local endpoint = string.format("/projects/%s/issues_statistics", project)
			return service.request("GET", endpoint, nil, done, {
				action = "Fetch repository issue statistics",
				repo = path,
			})
		end,
	}, function(results, errors)
		if errors.issues then
			on_done(nil, errors.issues)
			return
		end

		local entries = {}
		for _, raw_value in ipairs(json.safe_table(results.issues)) do
			local raw = json.safe_table(raw_value)
			local author = json.safe_table(raw.author)
			table.insert(entries, {
				number = raw.iid,
				title = json.safe_str(raw.title) or "",
				state = (json.safe_str(raw.state) or ""):lower() == "closed" and "closed" or "open",
				author = json.safe_str(author.username) or json.safe_str(author.name) or "",
				created_at = json.safe_str(raw.created_at) or "",
				comments = tonumber(raw.user_notes_count) or 0,
				url = json.safe_str(raw.web_url) or "",
			})
		end

		local counts
		local statistics = json.nilify(results.statistics)
		if statistics then
			local raw_counts = json.safe_table(json.safe_table(statistics.statistics).counts)
			counts = {
				open = tonumber(raw_counts.opened) or 0,
				closed = tonumber(raw_counts.closed) or 0,
			}
		end

		on_done({ entries = entries, counts = counts }, nil)
	end)
	return requests
end

---@param repo PullsRepoDetails
---@param branch PullsRepoBranch
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_branch(repo, branch, on_done)
	local path = repo_path(repo)
	local name = tostring(branch.name or "")
	if path == "" or name == "" then
		vim.schedule(function()
			on_done(false, "Missing branch info")
		end)
		return nil
	end

	local endpoint =
		string.format("/projects/%s/repository/branches/%s", service.url_encode(path), service.url_encode(name))
	return service.request("DELETE", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.delete_memory_cache(string.format("gitlab:branches:%s", path))
		on_done(true, nil)
	end, {
		action = "Delete repository branch",
		repo = path,
		branch = name,
	})
end

return M
