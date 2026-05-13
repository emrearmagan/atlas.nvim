local M = {}

local service = require("atlas.pulls.providers.bitbucket.api.service")
local api_utils = require("atlas.core.utils")
local as_table = api_utils.as_table

---@param user table|nil
---@return {name: string, nickname: string|nil, id: string}
local function actor(user)
	local u = as_table(user) or {}
	return {
		name = tostring(u.display_name or "Unknown"),
		nickname = tostring(u.nickname or ""),
		id = tostring(u.account_id or ""),
	}
end

---@param raw_inline table|nil
---@return {path: string, to: number|nil, from: number|nil}|nil
local function comment_inline(raw_inline)
	local inline = as_table(raw_inline)
	if inline == nil then
		return nil
	end
	local path = tostring(inline.path or "")
	local from = tonumber(inline["from"])
	local to = tonumber(inline["to"])
	if path == "" and from == nil and to == nil then
		return nil
	end
	return { path = path, ["from"] = from, ["to"] = to }
end

---@param result table|nil
---@return PullsComment|nil
local function normalize_comment(result)
	local entry = as_table(result)
	if entry == nil then
		return nil
	end
	local content = as_table(entry.content) or {}
	local links = as_table(entry.links) or {}
	local parent = as_table(entry.parent)

	return {
		id = tonumber(entry.id) or 0,
		parent_id = parent ~= nil and tonumber(parent.id) or nil,
		author = actor(entry.user),
		content_raw = tostring(content.raw or ""),
		created_on = tostring(entry.created_on or ""),
		inline = comment_inline(entry.inline),
		is_task = nil,
		state = entry.deleted == true and "DELETED" or nil,
		url = tostring((as_table(links.self) or {}).href or ""),
		html_url = tostring((as_table(links.html) or {}).href or ""),
		_raw = entry,
	}
end

---@param result table|nil
---@return PullsComment[]
local function normalize_comments(result)
	local payload = as_table(result) or {}
	local entries = {}

	for _, item in ipairs(payload.values or {}) do
		local entry = normalize_comment(item)
		if entry ~= nil then
			table.insert(entries, entry)
		end
	end

	return entries
end

---@param result table|nil
---@return BitbucketPRTasks
local function normalize_tasks(result)
	local payload = as_table(result) or {}
	local entries = {}

	for _, item in ipairs(payload.values or {}) do
		local task = as_table(item) or {}
		local content = as_table(task.content) or {}
		local links = as_table(task.links) or {}
		local comment = as_table(task.comment)
		local comment_links = as_table(comment and comment.links or nil) or {}

		table.insert(entries, {
			id = tonumber(task.id) or 0,
			state = tostring(task.state or ""),
			content_raw = tostring(content.raw or ""),
			created_on = tostring(task.created_on or ""),
			updated_on = tostring(task.updated_on or ""),
			resolved_on = task.resolved_on ~= nil and tostring(task.resolved_on) or nil,
			pending = task.pending == true,
			creator = actor(task.creator),
			comment_id = comment ~= nil and tonumber(comment.id) or nil,
			links = {
				self = tostring((as_table(links.self) or {}).href or ""),
				html = tostring((as_table(links.html) or {}).href or ""),
			},
			comment_html = tostring((as_table(comment_links.html) or {}).href or ""),
		})
	end

	return {
		entries = entries,
		size = payload.size ~= nil and tonumber(payload.size) or nil,
		page = payload.page ~= nil and tonumber(payload.page) or nil,
		pagelen = payload.pagelen ~= nil and tonumber(payload.pagelen) or nil,
		next = payload.next ~= nil and tostring(payload.next) or nil,
	}
end

---@param raw_content string
---@param opts? { parent_id?: number|string|nil, inline?: { from?: number, to?: number, start_from?: number, start_to?: number, path?: string }|nil }
---@return string
local function encode_comment_payload(raw_content, opts)
	opts = opts or {}
	local payload = {
		content = { raw = tostring(raw_content or "") },
	}

	if opts.parent_id ~= nil then
		payload.parent = { id = tonumber(opts.parent_id) or opts.parent_id }
	end

	if type(opts.inline) == "table" then
		payload.inline = {
			from = opts.inline.from,
			to = opts.inline.to,
			start_from = opts.inline.start_from,
			start_to = opts.inline.start_to,
			path = opts.inline.path,
		}
	end

	return vim.json.encode(payload)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(pr, opts, on_done)
	local raw = pr._raw or {}
	local comments_url = tostring((raw.links or {}).comments or "")
	if comments_url == "" then
		on_done({}, nil)
		return nil
	end

	local force = (opts or {}).force_refresh == true
	local sep = comments_url:find("?") and "&" or "?"
	local url = string.format("%s%spagelen=%d", comments_url, sep, 100)
	local key = "bitbucket:pr:comments:" .. url
	if not force then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.request("GET", url, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local comments = normalize_comments(result)
		service.set_cache(key, comments, service.cache_ttl())
		on_done(comments, nil)
	end)
end

---@param pr PullRequest
---@param content string
---@param opts? { inline?: { from?: number, to?: number, start_from?: number, start_to?: number, path?: string }|nil }
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(pr, content, opts, on_done)
	if type(opts) == "function" and on_done == nil then
		on_done = opts
		opts = nil
	end
	local raw = pr._raw or {}
	local comments_url = tostring((raw.links or {}).comments or "")
	if comments_url == "" then
		on_done(nil, "No comments URL available")
		return nil
	end

	local body = encode_comment_payload(content, { inline = opts and opts.inline or nil })
	return service.request("POST", comments_url, nil, body, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(normalize_comment(result), nil)
	end)
end

---@param pr PullRequest
---@param parent_id number|string
---@param content string
---@param opts? { inline?: { from?: number, to?: number, start_from?: number, start_to?: number, path?: string }|nil }
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.reply_comment(pr, parent_id, content, opts, on_done)
	if type(opts) == "function" and on_done == nil then
		on_done = opts
		opts = nil
	end
	local raw = pr._raw or {}
	local comments_url = tostring((raw.links or {}).comments or "")
	if comments_url == "" then
		on_done(nil, "No comments URL available")
		return nil
	end

	local body = encode_comment_payload(content, {
		parent_id = parent_id,
		inline = opts and opts.inline or nil,
	})
	return service.request("POST", comments_url, nil, body, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(normalize_comment(result), nil)
	end)
end

---@param pr PullRequest
---@param comment_id number|string|string
---@param content string
---@param opts? { inline?: { from?: number, to?: number, start_from?: number, start_to?: number, path?: string }|nil }
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(pr, comment_id, content, opts, on_done)
	if type(opts) == "function" and on_done == nil then
		on_done = opts
		opts = nil
	end
	local raw = pr._raw or {}
	local comments_url = tostring((raw.links or {}).comments or "")
	if comments_url == "" then
		on_done(nil, "No comments URL available")
		return nil
	end

	local url = comments_url .. "/" .. tostring(comment_id)
	local body = encode_comment_payload(content, { inline = opts and opts.inline or nil })
	return service.request("PUT", url, nil, body, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(normalize_comment(result), nil)
	end)
end

---@param pr PullRequest
---@param comment_id number|string|string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(pr, comment_id, on_done)
	local raw = pr._raw or {}
	local comments_url = tostring((raw.links or {}).comments or "")
	if comments_url == "" then
		on_done(false, "No comments URL available")
		return nil
	end

	local url = comments_url .. "/" .. tostring(comment_id)
	return service.request("DELETE", url, nil, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end)
end

---@class BitbucketPRTasks
---@field entries BitbucketPRTask[]
---@field size number|nil
---@field page number|nil
---@field pagelen number|nil
---@field next string|nil

---@param workspace string
---@param repo string
---@param pr_id string|number
---@param opts? { force_refresh?: boolean, pagelen?: number }
---@param on_done fun(tasks: BitbucketPRTasks|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_tasks(workspace, repo, pr_id, opts, on_done)
	opts = opts or {}

	local ws = tostring(workspace or "")
	local rp = tostring(repo or "")
	local id = tostring(pr_id or "")
	if ws == "" or rp == "" or id == "" then
		on_done(nil, "Missing Bitbucket PR task endpoint params")
		return nil
	end

	local endpoint = string.format("/repositories/%s/%s/pullrequests/%s/tasks", ws, rp, id)
	local sep = endpoint:find("?") and "&" or "?"
	local url = string.format("%s%spagelen=%d", endpoint, sep, tonumber(opts.pagelen) or 100)
	local key = string.format("bitbucket:pr:tasks:%s/%s/%s:%d", ws, rp, id, tonumber(opts.pagelen) or 100)
	if opts.force_refresh ~= true then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.request("GET", url, nil, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local tasks = normalize_tasks(result)
		service.set_cache(key, tasks, service.cache_ttl())
		on_done(tasks, nil)
	end)
end

---@param task_url string
---@param opts { state?: "RESOLVED"|"UNRESOLVED"|string, content_raw?: string }|nil
---@param on_done fun(task: BitbucketPRTask|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_task(task_url, opts, on_done)
	opts = opts or {}

	local url = tostring(task_url or "")
	if url == "" then
		on_done(nil, "Missing Bitbucket task URL")
		return nil
	end

	local payload = {}
	if type(opts.content_raw) == "string" and opts.content_raw ~= "" then
		payload.content = { raw = opts.content_raw }
	end
	if type(opts.state) == "string" and opts.state ~= "" then
		payload.state = opts.state
	end

	local body = vim.json.encode(payload)
	return service.request("PUT", url, nil, body, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local normalized = normalize_tasks({ values = { result } })
		local entries = (normalized or {}).entries or {}
		on_done(entries[1] or nil, nil)
	end)
end

---@param task_url string
---@param on_done fun(result: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_task(task_url, on_done)
	local url = tostring(task_url or "")
	if url == "" then
		on_done(nil, "Missing Bitbucket task URL")
		return nil
	end

	return service.request("DELETE", url, nil, nil, on_done)
end

---@param workspace string
---@param repo string
---@param pr_id string|number
---@param raw string
---@param opts? { comment_id?: number|string|nil }
---@param on_done fun(task: BitbucketPRTask|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_task(workspace, repo, pr_id, raw, opts, on_done)
	opts = opts or {}

	local ws = tostring(workspace or "")
	local rp = tostring(repo or "")
	local id = tostring(pr_id or "")
	if ws == "" or rp == "" or id == "" then
		on_done(nil, "Missing Bitbucket PR task endpoint params")
		return nil
	end

	local endpoint = string.format("/repositories/%s/%s/pullrequests/%s/tasks", ws, rp, id)
	local payload = {
		content = { raw = tostring(raw or "") },
	}
	if opts.comment_id ~= nil and tostring(opts.comment_id) ~= "" then
		payload.comment = { id = tonumber(opts.comment_id) or opts.comment_id }
	end

	local body = vim.json.encode(payload)
	return service.request("POST", endpoint, nil, body, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local normalized = normalize_tasks({ values = { result } })
		local entries = (normalized or {}).entries or {}
		on_done(entries[1] or nil, nil)
	end)
end

return M
