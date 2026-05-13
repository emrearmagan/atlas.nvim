local M = {}

local cli = require("atlas.pulls.providers.github.api.cli")

---@param repo PullsRepo
---@param opts PullsFetchOpts
---@param on_done fun(details: PullsRepoDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_detail(repo, opts, on_done)
	local owner = tostring(repo.owner or "")
	local repo_name = tostring(repo.repo_name or repo.name or "")

	if owner == "" or repo_name == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local slug = owner .. "/" .. repo_name
	local cache_key = string.format("github:repo_details:%s", slug)

	if not opts.force_load then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"repo",
		"view",
		slug,
		"--json",
		"name,nameWithOwner,owner,description,defaultBranchRef,isPrivate,createdAt,diskUsage,url,stargazerCount,forkCount,watchers",
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch repo details")
			return
		end

		local owner_login = type(result.owner) == "table" and tostring(result.owner.login or "") or owner

		---@type PullsRepoDetails
		local details = {
			id = tostring(result.nameWithOwner or slug),
			name = tostring(result.name or repo_name),
			full_name = tostring(result.nameWithOwner or slug),
			owner = owner_login,
			repo_name = tostring(result.name or repo_name),
			html_url = tostring(result.url or ""),
			description = tostring(result.description or ""),
			size = tonumber(result.diskUsage) or nil,
			default_branch = type(result.defaultBranchRef) == "table" and tostring(result.defaultBranchRef.name or "")
				or nil,
			is_private = result.isPrivate == true,
			created_on = tostring(result.createdAt or ""),
			readme = nil,
			stars = tonumber(result.stargazerCount) or nil,
			forks = tonumber(result.forkCount) or nil,
			watchers = type(result.watchers) == "table" and tonumber(result.watchers.totalCount) or nil,
			_raw = result,
		}

		cli.gh({
			"api",
			string.format("repos/%s/readme", slug),
			"--header",
			"Accept: application/vnd.github.raw+json",
		}, function(readme_result, readme_err)
			if not readme_err and readme_result then
				details.readme = tostring(readme_result)
			end
			cli.set_mem(cache_key, details)
			on_done(details, nil)
		end)
	end)
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(branches: PullsRepoBranches|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_branches(repo, opts, on_done)
	local slug = tostring(repo.full_name or "")
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local cache_key = string.format("github:branches:%s", slug)
	if not opts.force_load then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"api",
		string.format("repos/%s/branches?per_page=100", slug),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch branches")
			return
		end

		local entries = {}
		for _, branch in ipairs(result) do
			local commit = type(branch.commit) == "table" and branch.commit or {}
			table.insert(entries, {
				name = tostring(branch.name or ""),
				hash = tostring(commit.sha or ""):sub(1, 8),
				date = nil,
				message = nil,
				author = nil,
			})
		end

		local branches = { entries = entries }
		cli.set_mem(cache_key, branches)
		on_done(branches, nil)
	end)
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(tags: PullsRepoTags|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_tags(repo, opts, on_done)
	local slug = tostring(repo.full_name or "")
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local cache_key = string.format("github:tags:%s", slug)
	if not opts.force_load then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"api",
		string.format("repos/%s/tags?per_page=100", slug),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch tags")
			return
		end

		local entries = {}
		for _, tag in ipairs(result) do
			local commit = type(tag.commit) == "table" and tag.commit or {}
			table.insert(entries, {
				name = tostring(tag.name or ""),
				hash = tostring(commit.sha or ""):sub(1, 8),
				date = nil,
				message = nil,
				author = nil,
			})
		end

		local tags = { entries = entries }
		cli.set_mem(cache_key, tags)
		on_done(tags, nil)
	end)
end

return M
