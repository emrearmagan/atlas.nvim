local M = {}

local service = require("atlas.pulls.providers.bitbucket.api.service")
local mapper = require("atlas.pulls.providers.bitbucket.api.mapper")

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
		local comments = mapper.to_comments_list(result)
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
		on_done(mapper.to_comment(result), nil)
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
		on_done(mapper.to_comment(result), nil)
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
		on_done(mapper.to_comment(result), nil)
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

---@class BitbucketPRTask
---@field id number
---@field state string
---@field content_raw string
---@field created_on string
---@field updated_on string
---@field resolved_on string|nil
---@field pending boolean|nil
---@field creator {name: string, nickname: string|nil, id: string|nil}
---@field comment_id number|nil
---@field links {self: string, html: string}
---@field comment_html string

---@param workspace string
---@param repo string
---@param pr_id string|number
---@param opts? { force_refresh?: boolean, pagelen?: number }
---@param on_done fun(tasks: BitbucketPRTask[]|nil, err: string|nil)
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

		local tasks = mapper.to_tasks_list(result)
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

		local entries = mapper.to_tasks_list({ values = { result } })
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

		local entries = mapper.to_tasks_list({ values = { result } })
		on_done(entries[1] or nil, nil)
	end)
end

return M
