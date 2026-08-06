local M = {}

local service = require("atlas.providers.gitlab.client").pulls
local mapper = require("atlas.pulls.providers.gitlab.api.mapper")

---@param pr PullRequest
---@return string project_path, integer|nil iid
local function project_iid(pr)
	return pr.repo_full_name, tonumber(pr.id)
end

local function same_actor(left, right)
	local left_actor = left and left.actor or nil
	local right_actor = right and right.actor or nil
	return left_actor ~= nil
		and right_actor ~= nil
		and tostring(left_actor.username or left_actor.nickname or left_actor.name or "")
			== tostring(right_actor.username or right_actor.nickname or right_actor.name or "")
end

local function is_inline_thread_activity(entry)
	return type(entry) == "table" and type(entry._raw) == "table" and entry._raw.gitlab_inline_thread_activity == true
end

---@param entries PullsActivityEntry[]
---@return PullsActivityEntry[]
local function squash_inline_thread_activity(entries)
	local squashed, current, count = {}, nil, 0

	local function flush()
		if not current then
			return
		end
		if count > 1 then
			current = {
				kind = "comment",
				actor = current.actor,
				date = current.date,
				label = string.format("started %d review threads", count),
				_raw = { gitlab_inline_thread_activity = true },
			}
		end
		table.insert(squashed, current)
		current, count = nil, 0
	end

	for _, entry in ipairs(entries or {}) do
		if is_inline_thread_activity(entry) then
			if current and same_actor(current, entry) then
				count = count + 1
				current.date = entry.date or current.date
			else
				flush()
				current, count = entry, 1
			end
		else
			flush()
			table.insert(squashed, entry)
		end
	end
	flush()
	return squashed
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
	return service.fetch_all_pages(endpoint, function(result, err)
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
		entries = squash_inline_thread_activity(entries)
		service.set_memory_cache(cache_key, entries)
		on_done(entries, nil)
	end)
end

return M
