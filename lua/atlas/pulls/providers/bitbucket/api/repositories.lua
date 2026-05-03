local M = {}

local service = require("atlas.pulls.providers.bitbucket.api.service")
local logger = require("atlas.core.logger")
local config = require("atlas.config")
local api_utils = require("atlas.core.utils")
local as_table = api_utils.as_table

---@param raw table|nil
---@param fallback_workspace string|nil
---@return PullsRepoDetails
local function normalize_repo_details(raw, fallback_workspace)
	raw = type(raw) == "table" and raw or {}
	local workspace_obj = type(raw.workspace) == "table" and raw.workspace or {}
	local mainbranch = type(raw.mainbranch) == "table" and raw.mainbranch or {}
	local links = as_table(raw.links) or {}
	local html_link = as_table(links.html) or {}
	local full_name = tostring(raw.full_name or raw.name or raw.slug or "")
	local owner = tostring(workspace_obj.slug or fallback_workspace or "")
	local repo_name = tostring(raw.slug or raw.name or "")

	return {
		id = full_name ~= "" and full_name or repo_name,
		name = tostring(raw.name or repo_name or full_name),
		full_name = full_name,
		owner = owner,
		repo_name = repo_name,
		html_url = tostring(html_link.href or ""),
		description = tostring(raw.description or ""),
		size = tonumber(raw.size) or 0,
		default_branch = tostring(mainbranch.name or ""),
		is_private = raw.is_private == true,
		created_on = tostring(raw.created_on or ""),
		readme = nil,
		_raw = raw,
	}
end

---@param repo PullsRepo
---@return string|nil
local function configured_readme_path(repo)
	local repo_cfg = (((config.options or {}).pulls or {}).repo_config or {})
	local settings = repo_cfg.settings or {}
	local keys = {
		tostring(repo.id or ""),
		tostring(repo.name or ""),
	}

	for _, key in ipairs(keys) do
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
---@param ref string
---@param readme_path string|nil
---@param opts PullsFetchOpts
---@param on_done fun(readme: string|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
local function fetch_readme(owner, repo_name, ref, readme_path, opts, on_done)
	if owner == "" or repo_name == "" or ref == "" then
		on_done(nil, nil)
		return nil
	end

	local path = tostring(readme_path or "")
	if path == "" then
		path = "README.md"
	end

	local encoded_ref = ref:gsub(" ", "%%20")
	local encoded_path = path:gsub(" ", "%%20")
	local endpoint = string.format("/repositories/%s/%s/src/%s/%s", owner, repo_name, encoded_ref, encoded_path)

	return service.request_text("GET", endpoint, { Accept = "text/plain" }, nil, function(result, err)
		if err ~= nil then
			on_done(nil, err)
			return
		end

		on_done(tostring(result or ""), nil)
	end)
end

---@param workspace string
---@param search string
---@param on_done fun(repositories: PullsRepoDetails[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_workspace_repositories(workspace, search, on_done)
	if type(workspace) ~= "string" or workspace == "" then
		on_done(nil, "Missing workspace slug")
		return nil
	end
	local term = tostring(search or "")

	local query_prefix = ""
	if term ~= "" then
		local escaped_term = term:gsub('"', '\\"')
		local q_expression = string.format('name~"%s"', escaped_term)
		local encoded_q = q_expression:gsub('"', "%%22"):gsub(" ", "%%20")
		query_prefix = string.format("q=%s&", encoded_q)
	end

	local endpoint = string.format("/repositories/%s?%ssort=-updated_on&pagelen=50", workspace, query_prefix)

	logger.loginfo("Bitbucket repo fetch start", {
		workspace = workspace,
		search = term,
	})

	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err then
			logger.logerror("Bitbucket repo fetch failed", {
				workspace = workspace,
				search = term,
				error = err,
			})
			on_done(nil, err)
			return
		end

		local values = (result or {}).values or {}
		---@type PullsRepoDetails[]
		local repositories = {}
		for _, raw in ipairs(values) do
			table.insert(repositories, normalize_repo_details(raw, workspace))
		end

		logger.loginfo("Bitbucket repo fetch success", {
			workspace = workspace,
			search = term,
			repo_count = #repositories,
		})

		on_done(repositories, nil)
	end)
end

---@param repo PullsRepo
---@param opts PullsFetchOpts
---@param on_done fun(repo: PullsRepoDetails|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_detail(repo, opts, on_done)
	opts = opts or {}
	local owner = tostring(repo.owner or "")
	local repo_name = tostring(repo.repo_name or "")

	if owner == "" or repo_name == "" then
		on_done(nil, "Repository missing owner/name")
		return nil
	end

	local current = nil
	local cancelled = false
	local endpoint = string.format("/repositories/%s/%s", owner, repo_name)

	local function cancel()
		cancelled = true
		if current ~= nil and current.cancel then
			pcall(current.cancel)
		end
	end

	current = service.request("GET", endpoint, nil, nil, function(result, err)
		if cancelled then
			return
		end
		if err then
			on_done(nil, err)
			return
		end

		local detail = normalize_repo_details(result, owner)
		local readme_path = configured_readme_path(repo)
		local ref = tostring(detail.default_branch or "")

		current = fetch_readme(owner, repo_name, ref, readme_path, opts, function(readme, readme_err)
			if cancelled then
				return
			end
			if readme_err ~= nil then
				logger.logerror("Bitbucket repo readme fetch failed", {
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
		return nil
	end

	return {
		job_id = current.job_id,
		cancel = cancel,
	}
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
	local url = string.format("%s%spagelen=%d", branches_url, sep, tonumber(opts.pagelen) or 100)
	local key = "bitbucket:repo:branches:" .. url
	if opts.force_load ~= true then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.request("GET", url, nil, nil, function(result, err)
		if err ~= nil then
			on_done(nil, err)
			return
		end

		local payload = as_table(result) or {}
		local entries = {}
		for _, item in ipairs(payload.values or {}) do
			local branch = as_table(item) or {}
			local target = as_table(branch.target) or {}
			local author = as_table(target.author) or {}
			local user = as_table(author.user) or {}
			local links = as_table(branch.links) or {}
			local self_link = as_table(links.self) or {}
			local name = user.nickname or user.display_name or author.raw or ""
			table.insert(entries, {
				name = tostring(branch.name or ""),
				hash = tostring(target.hash or ""),
				date = tostring(target.date or ""),
				message = tostring(target.message or ""),
				author = tostring(name),
				api_url = tostring(self_link.href or ""),
			})
		end
		local branches = { entries = entries }
		service.set_cache(key, branches, service.cache_ttl())
		on_done(branches, nil)
	end)
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
	local url = string.format("%s%spagelen=%d", tags_url, sep, tonumber(opts.pagelen) or 100)
	local key = "bitbucket:repo:tags:" .. url
	if opts.force_load ~= true then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.request("GET", url, nil, nil, function(result, err)
		if err ~= nil then
			on_done(nil, err)
			return
		end

		local values = (as_table(result) or {}).values or {}
		local first = as_table(values[1]) or {}
		logger.loginfo("Bitbucket repo tags fetched", {
			url = url,
			count = #values,
			first_tag = tostring(first.name or ""),
		})

		local entries = {}
		for _, item in ipairs(values) do
			local tag = as_table(item) or {}
			local target = as_table(tag.target) or {}
			local author = as_table(target.author) or {}
			local user = as_table(author.user) or {}
			local name = user.nickname or user.display_name or author.raw or ""
			table.insert(entries, {
				name = tostring(tag.name or ""),
				hash = tostring(target.hash or ""),
				date = tostring(target.date or ""),
				message = tostring(target.message or ""),
				author = tostring(name),
			})
		end
		local tags = { entries = entries }
		service.set_cache(key, tags, service.cache_ttl())
		on_done(tags, nil)
	end)
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

	local endpoint = tostring(branch.api_url or "")
	if endpoint == "" then
		on_done(false, "Branch API URL is missing")
		return nil
	end

	return service.request("DELETE", endpoint, nil, nil, function(_, err)
		if err ~= nil then
			on_done(false, err)
			return
		end

		service.clear_cache()
		on_done(true, nil)
	end)
end

return M
