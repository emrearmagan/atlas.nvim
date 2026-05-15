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

---@param user any
---@return PullsAuthor|nil
local function actor_from(user)
	if type(user) ~= "table" then
		return nil
	end
	local username = tostring(user.username or "")
	if username == "" then
		return nil
	end
	return {
		name = tostring(user.name or username),
		id = tostring(user.id or ""),
		username = username,
		nickname = username,
	}
end

---@param body string
---@return "approval"|"changes_requested"|"update"
local function classify_system_note(body)
	local b = tostring(body or ""):lower()
	if b:find("unapproved this merge request", 1, true) then
		return "update"
	end
	if b:find("approved this merge request", 1, true) then
		return "approval"
	end
	if b:find("requested changes", 1, true) then
		return "changes_requested"
	end
	return "update"
end

---@param note table
---@return PullsActivityEntry|nil
local function entry_from_note(note)
	if note.system ~= true then
		return nil
	end
	local body = tostring(note.body or "")
	if body == "" then
		return nil
	end
	local first_line = body:match("([^\r\n]+)") or body
	local kind = classify_system_note(body)
	local content_raw = first_line
	if kind == "approval" or kind == "changes_requested" then
		content_raw = nil
	end
	return {
		kind = kind,
		actor = actor_from(note.author),
		date = tostring(note.created_at or ""),
		label = content_raw,
	}
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
				local e = entry_from_note(note)
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
