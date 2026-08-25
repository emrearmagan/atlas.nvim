local service = require("atlas.providers.gitea.client")
local pagination = require("atlas.providers.gitea.pagination")
local request_scope = require("atlas.core.requests")

local M = {}

---@param repo PullsRepo
---@return string
local function configured_readme_path(repo)
	local config = require("atlas.config")
	local settings = ((((config.options or {}).pulls or {}).repo_config or {}).settings or {})
	for _, key in ipairs({ repo.id, repo.full_name or "", repo.name }) do
		local entry = key ~= "" and settings[key] or nil
		if entry and vim.trim(tostring(entry.readme or "")) ~= "" then
			return tostring(entry.readme)
		end
	end
	return "README.md"
end

local function endpoint(slug)
	local owner, repo = slug:match("^([^/]+)/([^/]+)$")
	if owner then
		return string.format("/repos/%s/%s", service.url_encode(owner), service.url_encode(repo))
	end
end

---@param repo PullsRepo
---@param _ PullsFetchOpts
---@param on_done fun(repo: PullsRepoDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.detail(repo, _, on_done)
	local base = endpoint(repo.id)
	if not base then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end
	local requests = request_scope.new()
	requests.run(function(done)
		return service.request("GET", base, nil, done)
	end, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local full_name = raw.full_name
		local name = raw.name
		local owner = raw.owner
		local details = {
			id = full_name,
			name = name,
			full_name = full_name,
			owner = owner.login,
			repo_name = name,
			html_url = raw.html_url,
			description = raw.description or "",
			size = tonumber(raw.size),
			default_branch = raw.default_branch,
			is_private = raw.private == true,
			created_on = raw.created_at,
			readme = nil,
			stars = tonumber(raw.stars_count),
			watchers = tonumber(raw.watchers_count),
			forks = tonumber(raw.forks_count),
		}
		local ref = tostring(details.default_branch or "")
		if ref == "" then
			on_done(details, nil)
			return
		end
		local readme = configured_readme_path(repo)
		local target = string.format("%s/raw/%s%s", base, service.url_encode(readme), service.query({ ref = ref }))
		requests.run(function(done)
			return service.request_text("GET", target, done)
		end, function(body, readme_err)
			if readme_err and not readme_err:match("^HTTP 404") then
				on_done(nil, readme_err)
				return
			end
			if body and body ~= "" then
				details.readme = body
			end
			on_done(details, nil)
		end)
	end)
	return requests
end

---@param repo PullsRepoDetails
---@param kind "branches"|"tags"
---@param on_done fun(result: PullsRepoBranches|PullsRepoTags|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function refs(repo, kind, on_done)
	local base = endpoint(repo.full_name)
	if not base then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end
	return pagination.fetch_all(base .. "/" .. kind, nil, nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local entries = {}
		for _, value in ipairs(raw) do
			local name = value.name
			local commit = value.commit
			if kind == "tags" then
				table.insert(entries, {
					name = name,
					hash = commit.sha:sub(1, 8),
					date = "",
					message = value.message or "",
					author = "",
				})
			else
				local author = commit.author
				table.insert(entries, {
					name = name,
					hash = commit.id:sub(1, 8),
					date = commit.timestamp,
					message = commit.message,
					author = author.name,
					api_url = base .. "/branches/" .. service.url_encode(name),
				})
			end
		end
		on_done({ entries = entries }, nil)
	end)
end

function M.branches(repo, _, on_done)
	return refs(repo, "branches", on_done)
end

function M.tags(repo, _, on_done)
	return refs(repo, "tags", on_done)
end

---@param repo PullsRepoDetails
---@param state "open"|"closed"
---@param _opts PullsFetchOpts
---@param on_done fun(result: { entries: PullsRepoIssue[], counts: { open: integer, closed: integer }|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issues(repo, state, _opts, on_done)
	local base = endpoint(repo.full_name)
	if not base then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end
	return pagination.fetch_all(
		base .. "/issues",
		{ state = state, type = "issues" },
		{ max_items = 50 },
		function(issues, err)
			if err then
				on_done(nil, err)
				return
			end
			local result = {}
			for _, raw in ipairs(issues) do
				local reporter = raw.user
				table.insert(result, {
					number = raw.number,
					title = raw.title,
					state = raw.state:lower() == "closed" and "closed" or "open",
					author = reporter.login,
					created_at = raw.created_at,
					comments = raw.comments,
					url = raw.html_url,
				})
			end
			on_done({ entries = result, counts = nil }, nil)
		end
	)
end

---@param repo PullsRepoDetails
---@param branch PullsRepoBranch
---@param on_done fun(ok: boolean, err: string|nil)
function M.delete_branch(repo, branch, on_done)
	local base = endpoint(repo.full_name)
	local name = vim.trim(branch.name)
	if not base or name == "" then
		on_done(false, "Invalid Gitea branch")
		return nil
	end
	return service.request("DELETE", base .. "/branches/" .. service.url_encode(name), nil, function(_, err)
		on_done(err == nil, err)
	end)
end

---@param term string
---@param on_done fun(repositories: string[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.search(term, on_done)
	term = vim.trim(term)
	if term == "" then
		on_done({}, nil)
		return nil
	end
	return service.request("GET", "/repos/search" .. service.query({ q = term, limit = 20 }), nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local values = raw.data
		local result = {}
		for _, repo in ipairs(values) do
			table.insert(result, repo.full_name)
		end
		on_done(result, nil)
	end)
end

return M
