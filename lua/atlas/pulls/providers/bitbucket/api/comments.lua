local M = {}

local service = require("atlas.pulls.providers.bitbucket.api.service")
local mapper = require("atlas.pulls.providers.bitbucket.api.mapper")

---@param raw_content string
---@param opts? { parent_id?: number|string|nil, file?: PullsFileCommentPosition|nil, inline?: { from?: number, to?: number, start_from?: number, start_to?: number, path?: string }|nil, pending?: boolean|nil }
---@return string
local function encode_comment_payload(raw_content, opts)
	opts = opts or {}
	local payload = {
		content = { raw = tostring(raw_content or "") },
	}

	if opts.parent_id ~= nil then
		payload.parent = { id = tonumber(opts.parent_id) or opts.parent_id }
	end
	if opts.pending then
		payload.pending = true
	end

	if opts.inline then
		payload.inline = {
			from = opts.inline.from,
			to = opts.inline.to,
			start_from = opts.inline.start_from,
			start_to = opts.inline.start_to,
			path = opts.inline.path,
		}
	elseif opts.file then
		payload.inline = { path = opts.file.path }
	end

	return vim.json.encode(payload)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(pr, opts, on_done)
	local raw = pr._raw
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

	return service.fetch_all_values(url, function(result, err)
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
---@param opts PullsAddCommentOpts|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(pr, content, opts, on_done)
	local raw = pr._raw
	local comments_url = tostring((raw.links or {}).comments or "")
	if comments_url == "" then
		on_done(nil, "No comments URL available")
		return nil
	end

	local parent = opts and opts.parent or nil
	local body = encode_comment_payload(content, {
		parent_id = parent and (parent.parent_id or parent.id) or nil,
		file = opts and opts.file or nil,
		inline = opts and opts.inline or nil,
		pending = (opts and opts.pending == true) or (parent ~= nil and parent.state == "PENDING"),
	})
	return service.request("POST", comments_url, nil, body, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		service.clear_cache()
		local comment = mapper.to_comment(result)
		if comment == nil then
			on_done(nil, "Bitbucket did not return the created comment")
			return
		end
		on_done(comment, nil)
	end)
end

---@param pr PullRequest
---@param comment PullsComment
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(pr, comment, on_done)
	local raw = pr._raw
	local comments_url = tostring((raw.links or {}).comments or "")
	if comments_url == "" then
		on_done(nil, "No comments URL available")
		return nil
	end

	local url = comments_url .. "/" .. tostring(comment.id)
	local body = encode_comment_payload(comment.content_raw)
	return service.request("PUT", url, nil, body, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		service.clear_cache()
		local updated = mapper.to_comment(result)
		if updated == nil then
			on_done(nil, "Bitbucket did not return the updated comment")
			return
		end
		on_done(vim.tbl_extend("force", {}, comment, updated), nil)
	end)
end

---@param pr PullRequest
---@param comment PullsComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(pr, comment, on_done)
	local raw = pr._raw
	local comments_url = tostring((raw.links or {}).comments or "")
	if comments_url == "" then
		on_done(false, "No comments URL available")
		return nil
	end

	local url = comments_url .. "/" .. tostring(comment.id)
	return service.request("DELETE", url, nil, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.clear_cache()
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param root PullsComment
---@param resolved boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_thread_resolved(pr, root, resolved, on_done)
	local raw = pr._raw
	local comments_url = tostring((raw.links or {}).comments or "")
	if comments_url == "" then
		on_done(false, "No comments URL available")
		return nil
	end

	local url = string.format("%s/%s/resolve", comments_url, tostring(root.parent_id or root.id))
	return service.request_text(resolved and "POST" or "DELETE", url, nil, nil, function(_, err)
		if not err then
			service.clear_cache()
		end
		on_done(err == nil, err)
	end)
end

return M
