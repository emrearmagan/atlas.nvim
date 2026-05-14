local M = {}

local service = require("atlas.pulls.providers.gitlab.api.service")

---@param pr PullRequest
---@return string project_path, integer|nil iid
local function project_iid(pr)
	local raw = type(pr._raw) == "table" and pr._raw or {}
	local path = tostring(raw.project_path or pr.repo_full_name or "")
	local iid = tonumber(raw.iid or pr.id)
	return path, iid
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

	local endpoint = string.format("/projects/%s/merge_requests/%d/commits?per_page=100", service.url_encode(path), iid)
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local commits = {}
		for _, raw in ipairs(type(result) == "table" and result or {}) do
			if type(raw) == "table" then
				local hash = tostring(raw.id or "")
				local short = tostring(raw.short_id or (hash ~= "" and hash:sub(1, 8) or ""))
				local title = tostring(raw.title or raw.message or "")
				table.insert(commits, {
					hash = hash,
					short_hash = short ~= "" and short or nil,
					message = title:match("([^\r\n]+)") or title,
					author_name = tostring(raw.author_name or ""),
					author_nickname = nil,
					date = tostring(raw.authored_date or raw.committed_date or ""),
					html_url = type(raw.web_url) == "string" and raw.web_url or nil,
				})
			end
		end
		service.set_memory_cache(cache_key, commits)
		on_done(commits, nil)
	end)
end

return M
