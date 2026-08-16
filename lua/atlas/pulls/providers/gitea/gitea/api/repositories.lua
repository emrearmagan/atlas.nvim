local service = require("atlas.providers.gitea.gitea.client").pulls
local pagination = require("atlas.pulls.providers.gitea.gitea.api.pagination")
local request_scope = require("atlas.core.requests")

local M = {}

---@param repo PullsRepo
---@return string
local function configured_readme_path(repo)
	local config = require("atlas.config")
	local settings = ((((config.options or {}).pulls or {}).repo_config or {}).settings or {})
	for _, key in ipairs({ tostring(repo.id or ""), tostring(repo.full_name or ""), tostring(repo.name or "") }) do
		local entry = key ~= "" and settings[key] or nil
		if type(entry) == "table" and vim.trim(tostring(entry.readme or "")) ~= "" then
			return tostring(entry.readme)
		end
	end
	return "README.md"
end

local function endpoint(slug)
	local owner, repo = tostring(slug or ""):match("^([^/]+)/([^/]+)$")
	if owner then
		return string.format("/repos/%s/%s", service.url_encode(owner), service.url_encode(repo))
	end
end

function M.detail(repo, _, on_done)
	if type(repo) ~= "table" then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end
	local slug = tostring(repo.id or "")
	if not slug:find("/", 1, true) then
		slug = tostring(repo.owner or "") .. "/" .. tostring(repo.repo_name or repo.name or "")
	end
	local base = endpoint(slug)
	if not base then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end
	local requests = request_scope.new()
	requests.run(function(done)
		return service.request("GET", base, nil, done)
	end, function(raw, err)
		if err or type(raw) ~= "table" then
			on_done(nil, err or "Invalid repository response")
			return
		end
		local full_name = tostring(raw.full_name or slug)
		local details = {
			id = full_name,
			name = tostring(raw.name or ""),
			full_name = full_name,
			owner = type(raw.owner) == "table" and tostring(raw.owner.login or "") or repo.owner,
			repo_name = tostring(raw.name or ""),
			html_url = raw.html_url,
			description = tostring(raw.description or ""),
			size = raw.size,
			default_branch = raw.default_branch,
			is_private = raw.private == true,
			created_on = raw.created_at,
			readme = nil,
			stars = raw.stars_count,
			watchers = raw.watchers_count,
			forks = raw.forks_count,
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
		end, function(body)
			if type(body) == "string" and body ~= "" then
				details.readme = body
			end
			on_done(details, nil)
		end)
	end)
	return requests
end

local function refs(repo, kind, on_done)
	local base = type(repo) == "table" and endpoint(repo.full_name or repo.id) or nil
	if not base then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end
	return pagination.fetch_all(base .. "/" .. kind, nil, {
		invalid_response = "Invalid repository " .. kind .. " response",
	}, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local entries = {}
		for _, value in ipairs(raw or {}) do
			if type(value) ~= "table" or tostring(value.name or "") == "" then
				on_done(nil, "Invalid repository " .. kind .. " response")
				return
			end
			local commit = type(value.commit) == "table" and value.commit or {}
			if kind == "tags" then
				table.insert(entries, {
					name = tostring(value.name or ""),
					hash = tostring(commit.sha or commit.id or ""):sub(1, 8),
					date = "",
					message = tostring(value.message or ""),
					author = "",
				})
			else
				table.insert(entries, {
					name = tostring(value.name or ""),
					hash = tostring(commit.sha or commit.id or ""):sub(1, 8),
					date = tostring(commit.timestamp or ""),
					message = tostring(commit.message or ""),
					author = type(commit.author) == "table" and tostring(
						commit.author.name or commit.author.username or ""
					) or "",
					api_url = base .. "/branches/" .. service.url_encode(tostring(value.name or "")),
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

---@param slug string
---@param state "open"|"closed"
---@param on_done fun(issues: table[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issues(slug, state, on_done)
	local base = endpoint(slug)
	if not base then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end
	return pagination.fetch_all(base .. "/issues", { state = state, type = "issues" }, {
		max_items = 50,
		invalid_response = "Invalid Gitea issues response",
		accept = function(raw)
			return type(raw) == "table" and type(raw.pull_request) ~= "table"
		end,
	}, function(issues, err)
		if err then
			on_done(nil, err)
			return
		end
		local result = {}
		for _, raw in ipairs(issues or {}) do
			local reporter = type(raw.user) == "table" and raw.user or {}
			table.insert(result, {
				number = raw.number,
				title = tostring(raw.title or ""),
				state = tostring(raw.state or state):lower(),
				author = tostring(reporter.login or ""),
				created_at = tostring(raw.created_at or ""),
				comments = raw.comments or 0,
				url = tostring(raw.html_url or ""),
				labels = raw.labels or {},
			})
		end
		on_done(result, nil)
	end)
end

---@param repo PullsRepoDetails
---@param branch PullsRepoBranch
---@param on_done fun(ok: boolean, err: string|nil)
function M.delete_branch(repo, branch, on_done)
	local base = type(repo) == "table" and endpoint(repo.full_name or repo.id) or nil
	local name = type(branch) == "table" and vim.trim(tostring(branch.name or "")) or ""
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
	term = vim.trim(tostring(term or ""))
	if term == "" then
		on_done({}, nil)
		return nil
	end
	return service.request("GET", "/repos/search" .. service.query({ q = term, limit = 20 }), nil, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local values = type(raw) == "table" and raw.data or nil
		if type(values) ~= "table" then
			on_done(nil, "Invalid repository search response")
			return
		end
		local result = {}
		for _, repo in ipairs(values) do
			local full_name = type(repo) == "table" and tostring(repo.full_name or "") or ""
			if full_name ~= "" then
				table.insert(result, full_name)
			end
		end
		on_done(result, nil)
	end)
end

return M
