local M = {}

local service = require("atlas.pulls.providers.bitbucket.api.service")
local mapper = require("atlas.pulls.providers.bitbucket.api.server.mapper")
local logger = require("atlas.core.logger")
local config = require("atlas.config")

---@param repo PullsRepo
---@return string|nil
local function configured_readme_path(repo)
	local repo_cfg = (((config.options or {}).pulls or {}).repo_config or {})
	local settings = repo_cfg.settings or {}
	for _, key in ipairs({ tostring(repo.id or ""), tostring(repo.name or "") }) do
		if key ~= "" then
			local entry = settings[key]
			if type(entry) == "table" and tostring(entry.readme or "") ~= "" then
				return tostring(entry.readme)
			end
		end
	end
	return nil
end

---@param owner string
---@param repo_name string
---@param on_done fun(branch: string|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
local function fetch_default_branch(owner, repo_name, on_done)
	if owner == "" or repo_name == "" then
		on_done(nil, nil)
		return nil
	end
	local endpoint = string.format("/projects/%s/repos/%s/branches/default", owner, repo_name)
	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err and err:find("HTTP 404", 1, true) then
			on_done(nil, nil)
			return
		end
		if err then
			on_done(nil, err)
			return
		end
		local r = type(result) == "table" and result or {}
		on_done(tostring(r.displayId or r.id or ""), nil)
	end, { action = "Bitbucket Server default branch" })
end

---@param owner string
---@param repo_name string
---@param readme_path string|nil
---@param on_done fun(readme: string|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
local function fetch_readme(owner, repo_name, readme_path, on_done)
	if owner == "" or repo_name == "" then
		on_done(nil, nil)
		return nil
	end
	local path = (readme_path ~= nil and readme_path ~= "") and readme_path or "README.md"
	local encoded_path = path:gsub(" ", "%%20")
	local url = service.url(string.format("/projects/%s/repos/%s/raw/%s", owner, repo_name, encoded_path))
	return service.request_text("GET", url, { Accept = "text/plain" }, nil, function(text, err)
		if err and err:find("HTTP 404", 1, true) then
			on_done(nil, nil)
			return
		end
		if err then
			on_done(nil, err)
			return
		end
		on_done(tostring(text or ""), nil)
	end, { action = "Bitbucket Server readme" })
end

---@param s string
---@return string
local function url_encode(s)
	return (tostring(s or ""):gsub("([^%w%-_.~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

---@param workspace string  project key on Server
---@param search string
---@param on_done fun(repositories: PullsRepoDetails[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_workspace_repositories(workspace, search, on_done)
	if type(workspace) ~= "string" or workspace == "" then
		on_done(nil, "Missing project key")
		return nil
	end
	local term = tostring(search or "")
	local query = "limit=50"
	if term ~= "" then
		query = query .. "&name=" .. url_encode(term)
	end
	local endpoint = string.format("/projects/%s/repos?%s", workspace, query)

	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err then
			logger.logerror("Bitbucket Server repo fetch failed", {
				project = workspace,
				search = term,
				error = err,
			})
			on_done(nil, err)
			return
		end

		---@type PullsRepoDetails[]
		local repos = {}
		for _, raw in ipairs((type(result) == "table" and result.values) or {}) do
			table.insert(repos, mapper.to_repo_details(raw, workspace))
		end
		logger.loginfo("Bitbucket Server repo fetch success", {
			project = workspace,
			search = term,
			repo_count = #repos,
		})
		on_done(repos, nil)
	end, {
		action = "Bitbucket Server repo fetch",
		project = workspace,
		search = term,
	})
end

---@param repo PullsRepo
---@param opts PullsFetchOpts
---@param on_done fun(repo: PullsRepoDetails|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_detail(repo, opts, on_done) ---@diagnostic disable-line: unused-local
	local owner = tostring(repo.owner or "")
	local repo_name = tostring(repo.repo_name or "")
	if owner == "" or repo_name == "" then
		on_done(nil, "Repository missing owner/name")
		return nil
	end

	local cancelled = false
	local current = nil
	local function cancel()
		cancelled = true
		if current and current.cancel then
			pcall(current.cancel)
		end
	end

	local endpoint = string.format("/projects/%s/repos/%s", owner, repo_name)
	current = service.request("GET", endpoint, nil, nil, function(result, err)
		if cancelled then
			return
		end
		if err then
			on_done(nil, err)
			return
		end
		local detail = mapper.to_repo_details(result, owner)
		local readme_path = configured_readme_path(repo)

		current = fetch_default_branch(owner, repo_name, function(branch, branch_err)
			if cancelled then
				return
			end
			if branch_err ~= nil then
				logger.logerror("Bitbucket Server default branch fetch failed", {
					owner = owner,
					repo = repo_name,
					error = branch_err,
				})
			elseif branch and branch ~= "" then
				detail.default_branch = branch
			end

			current = fetch_readme(owner, repo_name, readme_path, function(readme, readme_err)
				if cancelled then
					return
				end
				if readme_err ~= nil then
					logger.logerror("Bitbucket Server readme fetch failed", {
						owner = owner,
						repo = repo_name,
						error = readme_err,
					})
				else
					detail.readme = readme
				end
				on_done(detail, nil)
			end)
			if current == nil then
				on_done(detail, nil)
			end
		end)
		if current == nil then
			on_done(detail, nil)
		end
	end, { action = "Bitbucket Server repo detail", project = owner, repo = repo_name })

	if current == nil then
		return nil
	end
	return { job_id = current.job_id, cancel = cancel }
end

---@param values table[]
---@return PullsRepoBranch[]
local function map_refs(values)
	local entries = {}
	for _, item in ipairs(values or {}) do
		local r = type(item) == "table" and item or {}
		table.insert(entries, {
			name = tostring(r.displayId or r.id or ""),
			hash = tostring(r.latestCommit or ""),
			date = "",
			message = "",
			author = "",
		})
	end
	return entries
end

---@param branches_url string
---@param opts PullsFetchOpts
---@param on_done fun(branches: PullsRepoBranches|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_branches(branches_url, opts, on_done)
	opts = opts or {}
	if type(branches_url) ~= "string" or branches_url == "" then
		on_done(nil, "Missing branches URL")
		return nil
	end
	local sep = branches_url:find("?") and "&" or "?"
	local url = string.format("%s%slimit=%d", branches_url, sep, tonumber(opts.pagelen) or 100)
	local key = "bitbucket-server:repo:branches:" .. url
	if opts.force_load ~= true then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end
	return service.request("GET", url, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local branches = { entries = map_refs((type(result) == "table" and result.values) or {}) }
		service.set_cache(key, branches, service.cache_ttl())
		on_done(branches, nil)
	end, { action = "Bitbucket Server branches" })
end

---@param tags_url string
---@param opts PullsFetchOpts
---@param on_done fun(tags: PullsRepoTags|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_tags(tags_url, opts, on_done)
	opts = opts or {}
	if type(tags_url) ~= "string" or tags_url == "" then
		on_done(nil, "Missing tags URL")
		return nil
	end
	local sep = tags_url:find("?") and "&" or "?"
	local url = string.format("%s%slimit=%d", tags_url, sep, tonumber(opts.pagelen) or 100)
	local key = "bitbucket-server:repo:tags:" .. url
	if opts.force_load ~= true then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end
	return service.request("GET", url, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local tags = { entries = map_refs((type(result) == "table" and result.values) or {}) }
		service.set_cache(key, tags, service.cache_ttl())
		on_done(tags, nil)
	end, { action = "Bitbucket Server tags" })
end

---@param repo PullsRepoDetails
---@param branch PullsRepoBranch
---@param on_done fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.delete_branch(repo, branch, on_done)
	local owner = tostring(repo.owner or "")
	local repo_name = tostring(repo.repo_name or "")
	local branch_name = tostring(branch.name or "")
	if owner == "" or repo_name == "" then
		on_done(false, "Repository missing owner/name")
		return nil
	end
	if branch_name == "" then
		on_done(false, "Branch name is missing")
		return nil
	end

	local url =
		service.server_url("/rest/branch-utils/1.0", string.format("/projects/%s/repos/%s/branches", owner, repo_name))
	local ref = branch_name:sub(1, 5) == "refs/" and branch_name or ("refs/heads/" .. branch_name)
	local body = vim.json.encode({ name = ref, dryRun = false })
	return service.request("DELETE", url, nil, body, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end, { action = "Bitbucket Server delete branch", branch = branch_name })
end

return M
