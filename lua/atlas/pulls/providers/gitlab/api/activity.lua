local M = {}

local service = require("atlas.pulls.providers.gitlab.api.service")
local mapper = require("atlas.pulls.providers.gitlab.api.mapper")

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
---@param on_done fun(entries: PullsActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(pr, opts, on_done)
	opts = opts or {}
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		vim.schedule(function()
			on_done(nil, "Invalid MR identifier")
		end)
		return nil
	end

	local cache_key = string.format("gitlab_pulls:activity:%s!%d", path, iid)
	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format(
		"/projects/%s/merge_requests/%d/notes?sort=asc&order_by=created_at&per_page=100",
		service.url_encode(path),
		iid
	)
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local entries = {}
		for _, note in ipairs(type(result) == "table" and result or {}) do
			if type(note) == "table" then
				local e = mapper.to_activity(note)
				if e then
					table.insert(entries, e)
				end
			end
		end
		service.set_memory_cache(cache_key, entries)
		on_done(entries, nil)
	end)
end

return M
