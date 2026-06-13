local M = {}

local cli = require("atlas.issues.providers.gitea.api.cli")
local mapper = require("atlas.issues.providers.gitea.api.mapper")

---@param key string
---@param on_done fun(comments: IssueComment[]|nil, err: string|nil)
---@param opts { force_load?: boolean }|nil
---@return { cancel: fun() }|nil
function M.list(key, on_done, opts)
	opts = opts or {}
	local slug, number = mapper.parse_key(key)
	if slug == "" or number == nil then
		vim.schedule(function()
			on_done(nil, "Invalid issue key")
		end)
		return nil
	end

	local cache_key = string.format("gitea_issues:comments:%s#%d", slug, number)
	if not opts.force_load then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/repos/%s/issues/%d/comments", slug, number)
	return cli.get(endpoint, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local comments = mapper.to_comments_list(type(result) == "table" and result or {})
		cli.set_mem(cache_key, comments)
		on_done(comments, nil)
	end, {
		action = "Gitea fetch issue comments",
		slug = slug,
		number = number,
	})
end

---@param key string
---@param body string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add(key, body, on_done)
	local slug, number = mapper.parse_key(key)
	if slug == "" or number == nil then
		vim.schedule(function()
			on_done(nil, "Invalid issue key")
		end)
		return nil
	end
	if type(body) ~= "string" or vim.trim(body) == "" then
		vim.schedule(function()
			on_done(nil, "Comment cannot be empty")
		end)
		return nil
	end

	local endpoint = string.format("/repos/%s/issues/%d/comments", slug, number)
	local payload = vim.json.encode({ body = body })
	return cli.api("POST", endpoint, payload, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		cli.delete_mem(string.format("gitea_issues:comments:%s#%d", slug, number))
		cli.delete_mem(string.format("gitea_issues:conversation:%s#%d", slug, number))
		on_done(mapper.to_comment(result), nil)
	end, {
		action = "Gitea add issue comment",
		slug = slug,
		number = number,
	})
end

---@param key string
---@param comment_id string|number
---@param body string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit(key, comment_id, body, on_done)
	local slug, number = mapper.parse_key(key)
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Invalid issue key")
		end)
		return nil
	end
	if type(body) ~= "string" or vim.trim(body) == "" then
		vim.schedule(function()
			on_done(nil, "Comment cannot be empty")
		end)
		return nil
	end

	local endpoint = string.format("/repos/%s/issues/comments/%s", slug, tostring(comment_id))
	local payload = vim.json.encode({ body = body })
	return cli.api("PATCH", endpoint, payload, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		if number ~= nil then
			cli.delete_mem(string.format("gitea_issues:comments:%s#%d", slug, number))
			cli.delete_mem(string.format("gitea_issues:conversation:%s#%d", slug, number))
		end
		on_done(mapper.to_comment(result), nil)
	end, {
		action = "Gitea edit issue comment",
		slug = slug,
		comment_id = comment_id,
	})
end

---@param key string
---@param comment_id string|number
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete(key, comment_id, on_done)
	local slug, number = mapper.parse_key(key)
	if slug == "" then
		vim.schedule(function()
			on_done(false, "Invalid issue key")
		end)
		return nil
	end

	local endpoint = string.format("/repos/%s/issues/comments/%s", slug, tostring(comment_id))
	return cli.api("DELETE", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		if number ~= nil then
			cli.delete_mem(string.format("gitea_issues:comments:%s#%d", slug, number))
			cli.delete_mem(string.format("gitea_issues:conversation:%s#%d", slug, number))
		end
		on_done(true, nil)
	end, {
		action = "Gitea delete issue comment",
		slug = slug,
		comment_id = comment_id,
	})
end

return M
