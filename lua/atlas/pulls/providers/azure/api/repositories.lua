local M = {}

local config = require("atlas.config")
local json = require("atlas.core.json")
local request_scope = require("atlas.core.requests")
local service = require("atlas.pulls.providers.azure.api.service")

---@param repo PullsRepo
---@return string
local function repo_endpoint(repo)
	return string.format(
		"/%s/_apis/git/repositories/%s",
		service.url_encode(repo.owner),
		service.url_encode(repo.repo_name)
	)
end

---@param repo PullsRepo
---@return string
local function configured_readme_path(repo)
	local settings = ((config.options.pulls or {}).repo_config or {}).settings or {}
	local entry = settings[repo.id] or settings[repo.name] or {}
	return entry.readme or "README.md"
end

---@param on_done fun(repositories: table[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repositories(on_done)
	local cached, ok = service.get_cache("repositories")
	if ok then
		on_done(cached, nil)
		return nil
	end

	return service.request("GET", "/_apis/git/repositories", nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		service.set_cache("repositories", result.value)
		on_done(result.value, nil)
	end, { action = "Fetch repositories" })
end

---@param repo PullsRepo
---@param opts PullsFetchOpts
---@param on_done fun(details: PullsRepoDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_detail(repo, opts, on_done)
	local endpoint = repo_endpoint(repo)
	local cache_key = "repo-details:" .. endpoint
	if not (opts or {}).force_refresh then
		local cached, ok = service.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local scope = request_scope.new()
	scope.run(function(done)
		return service.request("GET", endpoint, nil, done, {
			action = "Fetch repository details",
			repo = repo.id,
		})
	end, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local project = result.project.name
		---@type PullsRepoDetails
		local details = {
			id = project .. "/" .. result.name,
			name = result.name,
			full_name = project .. "/" .. result.name,
			owner = project,
			workspace = project,
			repo_name = result.name,
			html_url = result.webUrl,
			size = result.size,
			default_branch = (json.safe_str(result.defaultBranch) or ""):gsub("^refs/heads/", ""),
			is_private = result.project.visibility == "private",
		}
		if details.default_branch == "" then
			service.set_cache(cache_key, details)
			on_done(details, nil)
			return
		end

		local readme_path = configured_readme_path(repo)
		local query = service.build_query({
			path = readme_path,
			includeContent = true,
			["versionDescriptor.version"] = details.default_branch,
			["versionDescriptor.versionType"] = "branch",
		})
		scope.run(function(done)
			return service.request("GET", endpoint .. "/items" .. query, nil, done, {
				action = "Fetch repository README",
				repo = repo.id,
				path = readme_path,
			})
		end, function(item, readme_err)
			if not readme_err then
				details.readme = json.safe_str(item.content)
			end
			service.set_cache(cache_key, details)
			on_done(details, nil)
		end)
	end)
	return scope
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(branches: PullsRepoBranches|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_branches(repo, opts, on_done)
	local endpoint = repo_endpoint(repo) .. "/stats/branches"
	local cache_key = "repo-branches:" .. endpoint
	if not (opts or {}).force_refresh then
		local cached, ok = service.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local entries = {}
		for _, raw in ipairs(result.value) do
			table.insert(entries, {
				name = raw.name,
				hash = raw.commit.commitId,
				date = raw.commit.committer.date,
				message = raw.commit.comment,
				author = raw.commit.author.name,
			})
		end
		local branches = { entries = entries }
		service.set_cache(cache_key, branches)
		on_done(branches, nil)
	end, {
		action = "Fetch repository branches",
		repo = repo.id,
	})
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(tags: PullsRepoTags|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_tags(repo, opts, on_done)
	local endpoint = repo_endpoint(repo) .. "/refs"
	local cache_key = "repo-tags:" .. endpoint
	if not (opts or {}).force_refresh then
		local cached, ok = service.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local tags = { entries = {} }
	local scope = request_scope.new()
	local context = { action = "Fetch repository tags", repo = repo.id }

	---@param continuation_token string|nil
	local function fetch_page(continuation_token)
		local query = service.build_query({
			filter = "tags/",
			peelTags = true,
			["$top"] = 100,
			continuationToken = continuation_token,
		})
		scope.run(function(done)
			return service.request("GET", endpoint .. query, nil, done, context)
		end, function(result, err, headers)
			if err then
				on_done(nil, err)
				return
			end

			for _, raw in ipairs(result.value) do
				table.insert(tags.entries, {
					name = raw.name:gsub("^refs/tags/", ""),
					hash = json.safe_str(raw.peeledObjectId) or raw.objectId,
					author = json.safe_table(raw.creator).displayName,
				})
			end
			local next_token = headers["x-ms-continuationtoken"]
			if next_token then
				fetch_page(next_token)
				return
			end
			service.set_cache(cache_key, tags)
			on_done(tags, nil)
		end)
	end

	fetch_page(nil)
	return scope
end

---@param repo PullsRepoDetails
---@param branch PullsRepoBranch
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_branch(repo, branch, on_done)
	local endpoint = repo_endpoint(repo) .. "/refs"
	local payload = {
		{
			name = "refs/heads/" .. branch.name,
			oldObjectId = branch.hash,
			newObjectId = string.rep("0", 40),
		},
	}
	return service.request("POST", endpoint, payload, function(result, err)
		if err then
			on_done(false, err)
			return
		end
		local update = result.value[1]
		if not update.success then
			on_done(false, json.safe_str(update.customMessage) or update.updateStatus)
			return
		end
		service.clear_cache()
		on_done(true, nil)
	end, {
		action = "Delete repository branch",
		repo = repo.id,
		branch = branch.name,
	})
end

return M
