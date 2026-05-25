local M = {}

local service = require("atlas.issues.providers.gitlab.api.service")
local normalizer = require("atlas.issues.providers.gitlab.api.mapper")
local logger = require("atlas.core.logger")

---@param key string
---@param opts { force_load?: boolean }|nil
---@param on_done fun(notes: table[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_notes(key, opts, on_done)
	opts = opts or {}
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end

	local cache_key = string.format("gitlab:notes:%s#%d", path, iid)
	if not opts.force_load then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format(
		"/projects/%s/issues/%d/notes?per_page=100&sort=asc&order_by=created_at",
		service.url_encode(path),
		iid
	)
	logger.loginfo("GitLab fetch notes", { path = path, iid = iid })

	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local list = type(result) == "table" and result or {}
		service.set_memory_cache(cache_key, list)
		on_done(list, nil)
	end)
end

---@param key string
---@param opts { force_load?: boolean }|nil
---@param on_done fun(comments: IssueComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_comments(key, opts, on_done)
	return fetch_notes(key, opts, function(notes, err)
		if err or notes == nil then
			on_done(nil, err)
			return
		end
		local out = {}
		for _, raw in ipairs(notes) do
			if raw.system ~= true then
				local c = normalizer.to_comment_from_note(raw)
				if c then
					table.insert(out, c)
				end
			end
		end
		on_done(out, nil)
	end)
end

---@param key string
---@param opts { force_load?: boolean }|nil
---@param on_done fun(entries: IssueActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_history(key, opts, on_done)
	return fetch_notes(key, opts, function(notes, err)
		if err or notes == nil then
			on_done(nil, err)
			return
		end
		local out = {}
		for _, raw in ipairs(notes) do
			if raw.system == true then
				local entry = normalizer.to_activity_from_note(raw)
				if entry then
					table.insert(out, entry)
				end
			end
		end
		on_done(out, nil)
	end)
end

---@param key string
---@param body string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add(key, body, on_done)
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end
	if type(body) ~= "string" or vim.trim(body) == "" then
		on_done(nil, "Comment cannot be empty")
		return nil
	end

	local endpoint = string.format("/projects/%s/issues/%d/notes", service.url_encode(path), iid)
	return service.request("POST", endpoint, { body = body }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		service.delete_memory_cache(string.format("gitlab:notes:%s#%d", path, iid))
		on_done(normalizer.to_comment_from_note(result), nil)
	end)
end

---@param key string
---@param note_id string|number
---@param body string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit(key, note_id, body, on_done)
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end
	if type(body) ~= "string" or vim.trim(body) == "" then
		on_done(nil, "Comment cannot be empty")
		return nil
	end

	local endpoint = string.format("/projects/%s/issues/%d/notes/%s", service.url_encode(path), iid, tostring(note_id))
	return service.request("PUT", endpoint, { body = body }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		service.delete_memory_cache(string.format("gitlab:notes:%s#%d", path, iid))
		on_done(normalizer.to_comment_from_note(result), nil)
	end)
end

---@param key string
---@param note_id string|number
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete(key, note_id, on_done)
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(false, "Invalid issue key")
		return nil
	end

	local endpoint = string.format("/projects/%s/issues/%d/notes/%s", service.url_encode(path), iid, tostring(note_id))
	return service.request("DELETE", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.delete_memory_cache(string.format("gitlab:notes:%s#%d", path, iid))
		on_done(true, nil)
	end)
end

return M
