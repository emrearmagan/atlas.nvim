local M = {}

local cli = require("atlas.issues.providers.github.api.cli")
local normalizer = require("atlas.issues.providers.github.api.normalizer")
local logger = require("atlas.core.logger")

---@param key string
---@param on_done fun(comments: IssueComment[]|nil, err: string|nil)
---@param opts { force_load?: boolean }|nil
---@return { cancel: fun() }|nil
function M.list(key, on_done, opts)
	opts = opts or {}
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end

	local cache_key = string.format("github_issues:comments:%s#%d", slug, number)
	if not opts.force_load then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	logger.loginfo("GitHub fetch issue comments", { slug = slug, number = number })
	return cli.gh(
		{ "api", "--paginate", string.format("repos/%s/issues/%d/comments", slug, number) },
		function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			local comments = normalizer.normalize_comments(type(result) == "table" and result or {})
			cli.set_mem(cache_key, comments)
			on_done(comments, nil)
		end
	)
end

---@param key string
---@param body string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add(key, body, on_done)
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end
	if type(body) ~= "string" or vim.trim(body) == "" then
		on_done(nil, "Comment cannot be empty")
		return nil
	end

	return cli.api(
		"POST",
		string.format("repos/%s/issues/%d/comments", slug, number),
		{ body = body },
		function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Empty response")
				return
			end
			cli.delete_cache(string.format("github_issues:comments:%s#%d", slug, number))
			cli.delete_cache(string.format("github_issues:conversation:%s#%d", slug, number))
			on_done(normalizer.normalize_comment(result), nil)
		end
	)
end

---@param key string
---@param comment_id string|number
---@param body string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit(key, comment_id, body, on_done)
	local slug, _ = normalizer.parse_key(key)
	if slug == "" then
		on_done(nil, "Invalid issue key")
		return nil
	end
	if type(body) ~= "string" or vim.trim(body) == "" then
		on_done(nil, "Comment cannot be empty")
		return nil
	end

	return cli.api(
		"PATCH",
		string.format("repos/%s/issues/comments/%s", slug, tostring(comment_id)),
		{ body = body },
		function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Empty response")
				return
			end
			local _, number = normalizer.parse_key(key)
			if number ~= nil then
				cli.delete_cache(string.format("github_issues:comments:%s#%d", slug, number))
				cli.delete_cache(string.format("github_issues:conversation:%s#%d", slug, number))
			end
			on_done(normalizer.normalize_comment(result), nil)
		end
	)
end

---@param key string
---@param comment_id string|number
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete(key, comment_id, on_done)
	local slug, number = normalizer.parse_key(key)
	if slug == "" then
		on_done(false, "Invalid issue key")
		return nil
	end

	return cli.api(
		"DELETE",
		string.format("repos/%s/issues/comments/%s", slug, tostring(comment_id)),
		nil,
		function(_, err)
			if err then
				on_done(false, err)
				return
			end
			if number ~= nil then
				cli.delete_cache(string.format("github_issues:comments:%s#%d", slug, number))
				cli.delete_cache(string.format("github_issues:conversation:%s#%d", slug, number))
			end
			on_done(true, nil)
		end
	)
end

return M
