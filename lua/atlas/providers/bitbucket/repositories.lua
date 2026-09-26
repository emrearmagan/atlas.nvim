local M = {}

local service = require("atlas.providers.bitbucket.client")
local config = require("atlas.config")
local api_utils = require("atlas.core.utils")
local request_scope = require("atlas.core.requests")
local json = require("atlas.core.json")
local as_table = api_utils.as_table
local url_encode = api_utils.url_encode

---@class BitbucketRepository : AtlasRepository
---@field branches_url string|nil
---@field tags_url string|nil

---@class BitbucketRepositoryDetails : AtlasRepositoryDetails, BitbucketRepository

---@param raw table|nil
---@param fallback_workspace string|nil
---@param fallback_repo string|nil
---@return BitbucketRepository
function M.to_repository(raw, fallback_workspace, fallback_repo)
	raw = as_table(raw) or {}
	local workspace_obj = as_table(raw.workspace) or {}
	local links = as_table(raw.links) or {}
	local html_link = as_table(links.html) or {}
	local branches_link = as_table(links.branches) or {}
	local tags_link = as_table(links.tags) or {}
	local full_name = tostring(raw.full_name or "")
	local full_owner, full_repo = full_name:match("^([^/]+)/(.+)$")
	local owner = tostring(workspace_obj.slug or full_owner or fallback_workspace or "")
	local repo_name = tostring(raw.slug or full_repo or fallback_repo or raw.name or "")
	if full_name == "" then
		full_name = owner ~= "" and repo_name ~= "" and (owner .. "/" .. repo_name) or repo_name
	end

	return {
		id = full_name,
		name = tostring(raw.name or repo_name),
		full_name = full_name,
		owner = owner,
		repo_name = repo_name,
		html_url = tostring(html_link.href or ""),
		branches_url = json.safe_str(branches_link.href),
		tags_url = json.safe_str(tags_link.href),
	}
end

---@param raw table|nil
---@param fallback_workspace string|nil
---@return BitbucketRepositoryDetails
local function to_repo_details(raw, fallback_workspace)
	raw = as_table(raw) or {}
	local mainbranch = as_table(raw.mainbranch) or {}
	local repo = M.to_repository(raw, fallback_workspace)
	---@cast repo BitbucketRepositoryDetails
	repo.description = tostring(raw.description or "")
	repo.size = tonumber(raw.size) or 0
	repo.default_branch = tostring(mainbranch.name or "")
	repo.is_private = raw.is_private == true
	repo.created_on = tostring(raw.created_on or "")
	return repo
end

---@param repo AtlasRepository
---@return string|nil
local function configured_readme_path(repo)
	local repo_cfg = (((config.options or {}).pulls or {}).repo_config or {})
	local settings = repo_cfg.settings or {}
	local keys = {
		repo.id,
		repo.name,
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
---@param on_done fun(readme: string|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
local function fetch_readme(owner, repo_name, ref, readme_path, on_done)
	if owner == "" or repo_name == "" or ref == "" then
		on_done(nil, nil)
		return nil
	end

	local path = readme_path or ""
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
	end, {
		action = "Fetch repository README",
		owner = owner,
		repo = repo_name,
		ref = ref,
		path = path,
	})
end

---@param workspace string
---@param search string
---@param on_done fun(repositories: AtlasRepositoryDetails[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_workspace_repositories(workspace, search, on_done)
	if workspace == "" then
		on_done(nil, "Missing workspace slug")
		return nil
	end
	local query_prefix = ""
	if search ~= "" then
		local escaped_term = search:gsub('"', '\\"')
		local q_expression = string.format('name~"%s"', escaped_term)
		local encoded_q = q_expression:gsub('"', "%%22"):gsub(" ", "%%20")
		query_prefix = string.format("q=%s&", encoded_q)
	end

	local endpoint = string.format("/repositories/%s?%ssort=-updated_on&pagelen=50", workspace, query_prefix)

	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local values = (result or {}).values or {}
		---@type AtlasRepositoryDetails[]
		local repositories = {}
		for _, raw in ipairs(values) do
			table.insert(repositories, to_repo_details(raw, workspace))
		end

		on_done(repositories, nil)
	end, {
		action = "Fetch repositories",
		workspace = workspace,
		search = search,
	})
end

---@param project BitbucketProjectTarget
---@param opts PullsFetchOpts
---@param on_done fun(repositories: BitbucketRepoTarget[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_project_repositories(project, opts, on_done)
	local workspace = project.workspace
	local project_key = project.project

	local cache_key = string.format("bitbucket:project_repos:%s/%s", workspace, project_key)
	if opts.force_refresh ~= true then
		local cached, ok = service.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local query = url_encode(string.format('project.key="%s"', project_key))
	local endpoint =
		string.format("/repositories/%s?q=%s&pagelen=100&fields=values.slug,next", url_encode(workspace), query)
	return service.fetch_all_values(endpoint, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local repositories = {}
		for _, raw in ipairs(result.values) do
			table.insert(repositories, { workspace = workspace, repo = raw.slug })
		end

		service.set_cache(cache_key, repositories, service.cache_ttl())
		on_done(repositories, nil)
	end, {
		action = "Fetch project repositories",
		workspace = workspace,
		project = project_key,
	})
end

---@param targets BitbucketPullTarget[]
---@param opts PullsFetchOpts
---@param on_done fun(repositories: BitbucketRepoTarget[], errors: string[])
---@return AtlasRequestScope
function M.resolve_targets(targets, opts, on_done)
	local requests = request_scope.new()
	local starts = {}
	for index, target_ref in ipairs(targets) do
		local target = target_ref
		starts[index] = function(done)
			if target.repo then
				done({ target }, nil)
				return nil
			end
			---@cast target BitbucketProjectTarget
			return M.fetch_project_repositories(target, opts, done)
		end
	end

	requests.all(starts, function(resolved_targets, target_errors)
		local repositories, errors, seen = {}, {}, {}
		for index, target in ipairs(targets) do
			for _, repository in ipairs(resolved_targets[index] or {}) do
				local key = repository.workspace .. "/" .. repository.repo
				if not seen[key] then
					seen[key] = true
					table.insert(repositories, repository)
				end
			end
			if target_errors[index] then
				table.insert(errors, string.format("%s/%s: %s", target.workspace, target.project, target_errors[index]))
			end
		end
		on_done(repositories, errors)
	end)

	return requests
end

---@param repo AtlasRepository
---@param on_done fun(repo: AtlasRepositoryDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_details(repo, on_done)
	local owner = repo.owner
	local repo_name = repo.repo_name

	if owner == "" or repo_name == "" then
		on_done(nil, "Repository missing owner/name")
		return nil
	end

	local endpoint = string.format("/repositories/%s/%s", owner, repo_name)
	local requests = request_scope.new()
	requests.run(function(done)
		return service.request("GET", endpoint, nil, nil, done, {
			action = "Fetch repository details",
			owner = owner,
			repo = repo_name,
		})
	end, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local detail = to_repo_details(result, owner)
		local readme_path = configured_readme_path(repo)
		local ref = detail.default_branch or ""

		requests.run(function(done)
			return fetch_readme(owner, repo_name, ref, readme_path, done)
		end, function(readme, readme_err)
			if readme_err == nil then
				detail.readme = readme
			end
			on_done(detail, nil)
		end)
	end)
	return requests
end

---@param repo AtlasRepository
---@param opts { cursor?: string, search?: string }
---@param on_done fun(branches: AtlasRepositoryBranch[]|nil, err: string|nil, next_cursor: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_branches(repo, opts, on_done)
	---@cast repo BitbucketRepository
	local branches_url = repo.branches_url
		or string.format("/repositories/%s/%s/refs/branches", url_encode(repo.owner), url_encode(repo.repo_name))

	local sep = branches_url:find("?") and "&" or "?"
	local url = string.format("%s%spagelen=100", branches_url, sep)
	if opts.search and opts.search ~= "" then
		url = url .. "&q=" .. url_encode("name~" .. vim.json.encode(opts.search))
	end
	local cursor = opts.cursor
	if cursor and cursor ~= "" then
		url = cursor
	end

	return service.request("GET", url, nil, nil, function(result, err)
		if err ~= nil or type(result) ~= "table" then
			on_done(nil, err or "Invalid paginated response")
			return
		end

		---@type AtlasRepositoryBranch[]
		local branches = {}
		for _, item in ipairs(result.values or {}) do
			local branch = as_table(item) or {}
			local target = as_table(branch.target) or {}
			local author = as_table(target.author) or {}
			local user = as_table(author.user) or {}
			local links = as_table(branch.links) or {}
			local self_link = as_table(links.self) or {}
			local name = user.nickname or user.display_name or author.raw or ""
			table.insert(branches, {
				name = tostring(branch.name or ""),
				hash = tostring(target.hash or ""),
				date = tostring(target.date or ""),
				message = tostring(target.message or ""),
				author = tostring(name),
				api_url = tostring(self_link.href or ""),
			})
		end
		local next_cursor = json.safe_str(result.next)
		if next_cursor == "" then
			next_cursor = nil
		end
		on_done(branches, nil, next_cursor)
	end, { action = "Fetch repository branches", repo = repo.full_name })
end

---@param repo AtlasRepository
---@param opts { cursor?: string, search?: string }
---@param on_done fun(tags: AtlasRepositoryTag[]|nil, err: string|nil, next_cursor: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_tags(repo, opts, on_done)
	---@cast repo BitbucketRepository
	local tags_url = repo.tags_url
		or string.format("/repositories/%s/%s/refs/tags", url_encode(repo.owner), url_encode(repo.repo_name))

	local sep = tags_url:find("?") and "&" or "?"
	local url = string.format("%s%spagelen=100", tags_url, sep)
	if opts.search and opts.search ~= "" then
		url = url .. "&q=" .. url_encode("name~" .. vim.json.encode(opts.search))
	end
	local cursor = opts.cursor
	if cursor and cursor ~= "" then
		url = cursor
	end

	return service.request("GET", url, nil, nil, function(result, err)
		if err ~= nil or type(result) ~= "table" then
			on_done(nil, err or "Invalid paginated response")
			return
		end

		---@type AtlasRepositoryTag[]
		local entries = {}
		for _, item in ipairs(result.values or {}) do
			local tag = as_table(item) or {}
			local target = as_table(tag.target) or {}
			local author = as_table(target.author) or {}
			local user = as_table(author.user) or {}
			local tagger = as_table(tag.tagger) or {}
			local tagger_user = as_table(tagger.user) or {}
			local links = as_table(tag.links) or {}
			local html_link = as_table(links.html) or {}
			local name = json.safe_str(tagger_user.nickname)
				or json.safe_str(tagger_user.display_name)
				or json.safe_str(tagger.raw)
				or json.safe_str(user.nickname)
				or json.safe_str(user.display_name)
				or json.safe_str(author.raw)
			local annotation = json.safe_str(tag.message)
			if annotation == "" then
				annotation = nil
			end
			table.insert(entries, {
				name = tostring(tag.name or ""),
				hash = tostring(target.hash or ""),
				tag_date = json.safe_str(tag.date),
				description = annotation,
				message = annotation or json.safe_str(target.message),
				author = name,
				url = json.safe_str(html_link.href),
			})
		end
		local next_cursor = json.safe_str(result.next)
		if next_cursor == "" then
			next_cursor = nil
		end
		on_done(entries, nil, next_cursor)
	end, { action = "Fetch repository tags", repo = repo.full_name })
end

---@param repo AtlasRepository
---@param branch AtlasRepositoryBranch
---@param on_done fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.delete_branch(repo, branch, on_done)
	local branch_name = branch.name

	if branch_name == "" then
		on_done(false, "Branch name is missing")
		return nil
	end

	local endpoint = branch.api_url or ""
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
	end, { action = "Delete repository branch", repo = repo.full_name, branch = branch_name })
end

return M
