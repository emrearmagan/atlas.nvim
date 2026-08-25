local M = {}

local diff_parser = require("atlas.core.git.diff_parser")
local json = require("atlas.core.json")
local mapper = require("atlas.pulls.providers.bitbucket.api.mapper")
local service = require("atlas.pulls.providers.bitbucket.api.service")

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diffstat(pr, opts, on_done)
	---@cast pr BitbucketPullRequest
	local diffstat_url = tostring(pr.links.diffstat or "")
	if diffstat_url == "" then
		on_done({}, nil)
		return nil
	end
	local fields = "values.status,values.lines_added,values.lines_removed,values.old.path,values.new.path,next"
	local sep = diffstat_url:find("?") and "&" or "?"
	local url = string.format("%s%sfields=%s", diffstat_url, sep, fields)
	local key = "bitbucket:pr:diffstat:" .. url
	if not (opts or {}).force_refresh then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.fetch_all_values(url, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		---@type PullsDiffstatEntry[]
		local entries = {}
		for _, item in ipairs(result.values or {}) do
			local new_file = json.safe_table(item.new)
			local old_file = json.safe_table(item.old)
			local status = tostring(item.status or ""):lower()
			if status == "" then
				status = "modified"
			end

			table.insert(entries, {
				status = status,
				path = tostring(new_file.path or old_file.path or ""),
				old_path = old_file.path and tostring(old_file.path) or nil,
				lines_added = tonumber(item.lines_added) or 0,
				lines_removed = tonumber(item.lines_removed) or 0,
			})
		end

		service.set_cache(key, entries)
		on_done(entries, nil)
	end, { action = "Fetch PR diffstat", repo = pr.repo_full_name, id = pr.id })
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(commits: PullsCommit[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commits(pr, opts, on_done)
	---@cast pr BitbucketPullRequest
	local commits_url = tostring(pr.links.commits or "")
	if commits_url == "" then
		on_done({}, nil)
		return nil
	end

	local force = (opts or {}).force_refresh == true
	local sep = commits_url:find("?") and "&" or "?"
	local url = string.format("%s%spagelen=%d", commits_url, sep, 50)
	local key = "bitbucket:pr:commits:" .. url
	if not force then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.fetch_all_values(url, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local commits = mapper.to_commits_list(result)
		service.set_cache(key, commits, service.cache_ttl())
		on_done(commits, nil)
	end, { action = "Fetch PR commits", repo = pr.repo_full_name, id = pr.id })
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(files: DiffFile[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diff(pr, _opts, on_done)
	---@cast pr BitbucketPullRequest
	local diff_url = tostring(pr.links.diff or "")
	if diff_url == "" then
		on_done({}, nil)
		return nil
	end

	return service.request_text("GET", diff_url, nil, nil, function(text, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(diff_parser.parse(text or ""), nil)
	end, { action = "Fetch PR diff", repo = pr.repo_full_name, id = pr.id })
end

return M
