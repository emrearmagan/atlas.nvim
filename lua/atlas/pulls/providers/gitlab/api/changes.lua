local M = {}

local service = require("atlas.providers.gitlab.client")
local json = require("atlas.core.json")

local DIFF_STATS_QUERY = [[
query($path:ID!,$iid:String!){
  project(fullPath:$path){
    mergeRequest(iid:$iid){
      diffStats{path additions deletions}
    }
  }
}
]]

---@param pr PullRequest
---@return string project_path, integer|nil iid
local function project_iid(pr)
	return pr.repo_full_name, tonumber(pr.id)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(commits: PullsCommit[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commits(pr, opts, on_done)
	opts = opts or {}
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		vim.schedule(function()
			on_done(nil, "Invalid MR identifier")
		end)
		return nil
	end

	local cache_key = string.format("gitlab_pulls:commits:%s!%d", path, iid)
	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/projects/%s/merge_requests/%d/commits", service.url_encode(path), iid)
	return service.fetch_all_pages(endpoint, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local commits = {}
		for _, raw_value in ipairs(json.safe_table(result)) do
			local raw = json.safe_table(raw_value)
			local hash = tostring(raw.id or "")
			local short = tostring(raw.short_id or (hash ~= "" and hash:sub(1, 8) or ""))
			local message = tostring(raw.message or raw.title or "")
			table.insert(commits, {
				hash = hash,
				repo_full_name = path,
				short_hash = short ~= "" and short or nil,
				message = message,
				author_name = tostring(raw.author_name or ""),
				author_nickname = nil,
				date = tostring(raw.authored_date or raw.committed_date or ""),
				html_url = json.safe_str(raw.web_url),
			})
		end
		service.set_memory_cache(cache_key, commits)
		on_done(commits, nil)
	end, {
		action = "Fetch MR commits",
		project_path = path,
		iid = iid,
	})
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diffstat(pr, opts, on_done)
	opts = opts or {}
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		vim.schedule(function()
			on_done(nil, "Invalid MR identifier")
		end)
		return nil
	end

	local cache_key = string.format("gitlab_pulls:diffstat:%s!%d", path, iid)
	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.graphql(DIFF_STATS_QUERY, { path = path, iid = tostring(iid) }, function(result, err)
		local merge_request = json.nilify(json.safe_table(json.safe_table(result).project).mergeRequest)
		if err or not merge_request then
			on_done(nil, err or "GitLab did not return the merge request")
			return
		end

		local entries = {}
		for _, stat in ipairs(json.safe_table(merge_request.diffStats)) do
			table.insert(entries, {
				path = tostring(stat.path or ""),
				lines_added = tonumber(stat.additions) or 0,
				lines_removed = tonumber(stat.deletions) or 0,
			})
		end
		service.set_memory_cache(cache_key, entries)
		on_done(entries, nil)
	end, {
		action = "Fetch MR diffstat",
		project_path = path,
		iid = iid,
	})
end

return M
