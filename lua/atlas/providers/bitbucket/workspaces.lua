local M = {}

local service = require("atlas.providers.bitbucket.client")
local request_scope = require("atlas.core.requests")
local mapper = require("atlas.providers.bitbucket.mapper")
local url_encode = require("atlas.core.utils").url_encode

---@class BitbucketWorkspace
---@field administrator boolean
---@field slug string
---@field uuid string
---@field links_self string|nil

---@param on_done fun(workspaces: BitbucketWorkspace[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_workspaces(on_done)
	local workspace_cache_key = "bitbucket:mem:user_workspaces"
	local workspace_cached = service.get_cache(workspace_cache_key)
	if workspace_cached then
		on_done(workspace_cached, nil)
		return nil
	end

	return service.request("GET", "/user/workspaces", nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		---@type BitbucketWorkspace[]
		local workspaces = {}
		for _, entry in ipairs(result.values or {}) do
			local workspace = entry.workspace

			table.insert(workspaces, {
				administrator = entry.administrator == true,
				slug = tostring(workspace.slug or ""),
				uuid = tostring(workspace.uuid or ""),
				links_self = tostring(workspace.links.self.href),
			})
		end

		service.set_cache(workspace_cache_key, workspaces)

		on_done(workspaces, nil)
	end, { action = "Fetch workspaces" })
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
		query_prefix = "q=" .. url_encode("name~" .. vim.json.encode(search)) .. "&"
	end

	local endpoint =
		string.format("/repositories/%s?%ssort=-updated_on&pagelen=50", url_encode(workspace), query_prefix)

	return service.request("GET", endpoint, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local values = result.values or {}
		---@type AtlasRepositoryDetails[]
		local repositories = {}
		for _, raw in ipairs(values) do
			table.insert(repositories, mapper.to_repo_details(raw, workspace))
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
local function fetch_project_repositories(project, opts, on_done)
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

		service.set_cache(cache_key, repositories)
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
			return fetch_project_repositories(target, opts, done)
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

return M
