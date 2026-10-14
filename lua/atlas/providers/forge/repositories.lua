local factory = {}

---@class ForgeRepositoriesApi : AtlasRepositoryCapability
---@field search fun(term: string, on_done: fun(repositories: string[]|nil, err: string|nil)): ForgeRequestHandle|nil

---@param service ForgeService
---@return ForgeRepositoriesApi
function factory.new(service)
	local request_scope = require("atlas.core.requests")
	local provider_name = service.name
	---@type ForgeRepositoriesApi
	local M = {}

	---@param repo AtlasRepository
	---@return string
	local function configured_readme_path(repo)
		local config = require("atlas.config")
		local repo_config = config.options.pulls.repo_config
		local settings = repo_config and repo_config.settings or {}
		local keys = { repo.id, repo.name }
		if repo.full_name then
			table.insert(keys, 2, repo.full_name)
		end
		for _, key in ipairs(keys) do
			local entry = key ~= "" and settings[key] or nil
			if entry and entry.readme and vim.trim(entry.readme) ~= "" then
				return entry.readme
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

	---@param repo AtlasRepository
	---@param on_done fun(repo: AtlasRepositoryDetails|nil, err: string|nil)
	---@return { cancel: fun() }|nil
	function M.fetch_details(repo, on_done)
		local base = endpoint(repo.full_name)
		if not base then
			on_done(nil, "Invalid " .. provider_name .. " repository")
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
			end, function(body, readme_err, status)
				if readme_err and status ~= 404 then
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

	---@param repo AtlasRepository
	---@param kind "branches"|"tags"
	---@param opts { cursor?: string, search?: string }
	---@param on_done fun(result: table[]|nil, err: string|nil, next_cursor: string|nil)
	local function refs(repo, kind, opts, on_done)
		local base = endpoint(repo.full_name)
		if not base then
			on_done(nil, "Invalid " .. provider_name .. " repository")
			return nil
		end
		local page = math.max(1, math.floor(tonumber(opts.cursor) or 1))
		local limit = 50
		local search = vim.trim(opts.search or ""):lower()
		local function complete(raw, err)
			if err then
				on_done(nil, err)
				return
			end
			local entries = {}
			for _, value in ipairs(raw) do
				local name, commit = value.name, value.commit
				if search == "" or name:lower():find(search, 1, true) then
					if kind == "tags" then
						table.insert(entries, {
							name = name,
							hash = commit.sha,
							tag_date = commit.created,
							message = value.message,
							description = value.message,
							url = (repo.html_url or service.base_url() .. "/" .. repo.full_name)
								.. "/src/tag/"
								.. service.url_encode(name),
						})
					else
						table.insert(entries, {
							name = name,
							hash = commit.id,
							date = commit.timestamp,
							message = commit.message,
							author = (commit.author or {}).name,
							protected = value.protected == true,
							api_url = base .. "/branches/" .. service.url_encode(name),
						})
					end
				end
			end
			on_done(entries, nil, search == "" and #raw == limit and tostring(page + 1) or nil)
		end
		-- Branch/tag endpoints lack a common server-side search parameter.
		if search ~= "" then
			return service.fetch_all(base .. "/" .. kind, nil, nil, complete)
		end
		return service.request(
			"GET",
			base .. "/" .. kind .. service.query({ page = page, limit = limit }),
			nil,
			complete
		)
	end

	function M.fetch_branches(repo, opts, on_done)
		return refs(repo, "branches", opts, on_done)
	end

	function M.fetch_tags(repo, opts, on_done)
		return refs(repo, "tags", opts, on_done)
	end

	---@param repo AtlasRepositoryDetails
	---@param branch AtlasRepositoryBranch
	---@param on_done fun(ok: boolean, err: string|nil)
	function M.delete_branch(repo, branch, on_done)
		local base = endpoint(repo.full_name)
		local name = vim.trim(branch.name)
		if not base or name == "" then
			on_done(false, "Invalid " .. provider_name .. " branch")
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
		return service.request(
			"GET",
			"/repos/search" .. service.query({ q = term, limit = 20 }),
			nil,
			function(raw, err)
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
			end
		)
	end

	return M
end

return factory
