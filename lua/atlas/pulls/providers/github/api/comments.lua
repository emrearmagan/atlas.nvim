local M = {}

local cli = require("atlas.pulls.providers.github.api.cli")

---@param raw table
---@return PullsComment
local function normalize_comment(raw)
	local user = raw.user or {}
	local reactions = nil
	if type(raw.reactions) == "table" then
		reactions = {
			["+1"] = tonumber(raw.reactions["+1"]) or 0,
			["-1"] = tonumber(raw.reactions["-1"]) or 0,
			laugh = tonumber(raw.reactions.laugh) or 0,
			hooray = tonumber(raw.reactions.hooray) or 0,
			confused = tonumber(raw.reactions.confused) or 0,
			heart = tonumber(raw.reactions.heart) or 0,
			rocket = tonumber(raw.reactions.rocket) or 0,
			eyes = tonumber(raw.reactions.eyes) or 0,
		}
	end
	return {
		id = raw.id,
		parent_id = nil,
		author = {
			name = tostring(user.login or ""),
			nickname = tostring(user.login or ""),
			id = tostring(user.id or ""),
		},
		content_raw = tostring(raw.body or ""),
		created_on = tostring(raw.created_at or ""),
		deleted = false,
		inline = nil,
		url = nil,
		html_url = tostring(raw.html_url or ""),
		reactions = reactions,
	}
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(pr, opts, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = string.format("github:comments:%s:%s", repo_slug, tostring(pr.id))
	opts = opts or {}

	if not opts.force_refresh then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh(
		{ "api", string.format("repos/%s/issues/%s/comments", repo_slug, tostring(pr.id)) },
		function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Failed to fetch comments")
				return
			end

			local comments = {}
			for _, raw in ipairs(result) do
				table.insert(comments, normalize_comment(raw))
			end

			cli.set_cache(cache_key, comments)
			on_done(comments, nil)
		end
	)
end

---@param pr PullRequest
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(pr, content, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end
	return cli.api(
		"POST",
		string.format("repos/%s/issues/%s/comments", repo_slug, tostring(pr.id)),
		{ body = content },
		function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Failed to create comment")
				return
			end
			on_done(normalize_comment(result), nil)
		end
	)
end

---@param pr PullRequest
---@param comment_id number|string
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(pr, comment_id, content, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end
	return cli.api(
		"PATCH",
		string.format("repos/%s/issues/comments/%s", repo_slug, tostring(comment_id)),
		{ body = content },
		function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Failed to edit comment")
				return
			end
			on_done(normalize_comment(result), nil)
		end
	)
end

---@param pr PullRequest
---@param comment_id number|string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(pr, comment_id, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(false, "Missing repo")
		end)
		return nil
	end
	return cli.api(
		"DELETE",
		string.format("repos/%s/issues/comments/%s", repo_slug, tostring(comment_id)),
		nil,
		function(_, err)
			if err then
				on_done(false, err)
				return
			end
			on_done(true, nil)
		end
	)
end

return M
