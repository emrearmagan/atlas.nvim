local M = {
	-- fetch_releases = nil,
	-- fetch_release = nil,
}
---@cast M AtlasRepositoryCapability

local service = require("atlas.providers.bitbucket.client")
local config = require("atlas.config")
local api_utils = require("atlas.core.utils")
local request_scope = require("atlas.core.requests")
local json = require("atlas.core.json")
local mapper = require("atlas.providers.bitbucket.mapper")
local url_encode = api_utils.url_encode

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

	local encoded_path = path:gsub("[^/]+", url_encode)
	local endpoint = string.format(
		"/repositories/%s/%s/src/%s/%s",
		url_encode(owner),
		url_encode(repo_name),
		url_encode(ref),
		encoded_path
	)

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

	local endpoint =
		string.format("/repositories/%s/%s?fields=%%2Bmainbranch.target.hash", url_encode(owner), url_encode(repo_name))
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

		local detail = mapper.to_repo_details(result, owner)
		local readme_path = configured_readme_path(repo)
		local mainbranch = json.safe_table(result.mainbranch)
		local ref = json.safe_str(json.safe_table(mainbranch.target).hash) or ""

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

---@param base string
---@param opts { cursor?: string, search?: string }
---@return string
local function refs_url(base, opts)
	local sep = base:find("?") and "&" or "?"
	local url = string.format("%s%spagelen=100", base, sep)
	if opts.search and opts.search ~= "" then
		url = url .. "&q=" .. url_encode("name~" .. vim.json.encode(opts.search))
	end
	local cursor = opts.cursor
	if cursor and cursor ~= "" then
		url = cursor
	end
	return url
end

---@param repo AtlasRepository
---@param opts { cursor?: string, search?: string }
---@param on_done fun(branches: AtlasRepositoryBranch[]|nil, err: string|nil, next_cursor: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_branches(repo, opts, on_done)
	---@cast repo BitbucketRepository
	local branches_url = repo.branches_url
		or string.format("/repositories/%s/%s/refs/branches", url_encode(repo.owner), url_encode(repo.repo_name))

	local url = refs_url(branches_url, opts)

	return service.request("GET", url, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		---@type AtlasRepositoryBranch[]
		local branches = {}
		for _, item in ipairs(result.values or {}) do
			local branch = json.safe_table(item)
			local target = json.safe_table(branch.target)
			local author = json.safe_table(target.author)
			local user = json.safe_table(author.user)
			local links = json.safe_table(branch.links)
			local self_link = json.safe_table(links.self)
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

	local url = refs_url(tags_url, opts)

	return service.request("GET", url, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		---@type AtlasRepositoryTag[]
		local entries = {}
		for _, item in ipairs(result.values or {}) do
			local tag = json.safe_table(item)
			local target = json.safe_table(tag.target)
			local author = json.safe_table(target.author)
			local user = json.safe_table(author.user)
			local tagger = json.safe_table(tag.tagger)
			local tagger_user = json.safe_table(tagger.user)
			local links = json.safe_table(tag.links)
			local html_link = json.safe_table(links.html)
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
