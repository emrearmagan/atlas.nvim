local service = require("atlas.providers.gitea.gitea.client").pulls
local pagination = require("atlas.pulls.providers.gitea.gitea.api.pagination")
local request_scope = require("atlas.core.requests")
local json = require("atlas.core.json")

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
		if err then
			on_done(nil, err)
			return
		end
		local full_name = json.safe_str(raw.full_name)
		local name = json.safe_str(raw.name)
		if not full_name or not name then
			on_done(nil, "Invalid repository response")
			return
		end
		local owner = json.safe_table(json.nilify(raw.owner))
		local details = {
			id = full_name,
			name = name,
			full_name = full_name,
			owner = json.safe_str(owner.login) or tostring(repo.owner or ""),
			repo_name = name,
			html_url = json.safe_str(raw.html_url) or "",
			description = json.safe_str(raw.description) or "",
			size = tonumber(raw.size),
			default_branch = json.safe_str(raw.default_branch),
			is_private = raw.private == true,
			created_on = json.safe_str(raw.created_at) or "",
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
			value = json.safe_table(json.nilify(value))
			local name = json.safe_str(value.name)
			if not name or name == "" then
				on_done(nil, "Invalid repository " .. kind .. " response")
				return
			end
			local commit = json.safe_table(json.nilify(value.commit))
			if kind == "tags" then
				table.insert(entries, {
					name = name,
					hash = (json.safe_str(commit.sha) or json.safe_str(commit.id) or ""):sub(1, 8),
					date = "",
					message = json.safe_str(value.message) or "",
					author = "",
				})
			else
				local author = json.safe_table(json.nilify(commit.author))
				table.insert(entries, {
					name = name,
					hash = (json.safe_str(commit.sha) or json.safe_str(commit.id) or ""):sub(1, 8),
					date = json.safe_str(commit.timestamp) or "",
					message = json.safe_str(commit.message) or "",
					author = json.safe_str(author.name) or json.safe_str(author.username) or "",
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
	local slug = tostring(repo.full_name or repo.id or "")
	local base = endpoint(slug)
	if not base then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end
	return pagination.fetch_all(base .. "/issues", { state = state, type = "issues" }, {
		max_items = 50,
		invalid_response = "Invalid Gitea issues response",
		accept = function(raw)
			return json.nilify(json.safe_table(raw).pull_request) == nil
		end,
	}, function(issues, err)
		if err then
			on_done(nil, err)
			return
		end
		local result = {}
		for _, raw in ipairs(issues) do
			raw = json.safe_table(json.nilify(raw))
			local number = tonumber(raw.number)
			if not number then
				on_done(nil, "Invalid Gitea issue response")
				return
			end
			local reporter = json.safe_table(json.nilify(raw.user))
			table.insert(result, {
				number = number,
				title = json.safe_str(raw.title) or "",
				state = (json.safe_str(raw.state) or state):lower() == "closed" and "closed" or "open",
				author = json.safe_str(reporter.login) or "",
				created_at = json.safe_str(raw.created_at) or "",
				comments = tonumber(raw.comments) or 0,
				url = json.safe_str(raw.html_url) or "",
			})
		end
		on_done({ entries = result, counts = nil }, nil)
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
		local values = json.nilify(raw.data)
		if not values or not vim.islist(values) then
			on_done(nil, "Invalid repository search response")
			return
		end
		local result = {}
		for _, repo in ipairs(values) do
			repo = json.safe_table(json.nilify(repo))
			local full_name = json.safe_str(repo.full_name) or ""
			if full_name == "" then
				on_done(nil, "Invalid repository search response")
				return
			end
			table.insert(result, full_name)
		end
		on_done(result, nil)
	end)
end

return M
