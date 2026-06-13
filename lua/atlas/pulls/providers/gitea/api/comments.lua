local M = {}

local cli = require("atlas.pulls.providers.gitea.api.cli")
local mapper = require("atlas.pulls.providers.gitea.api.mapper")

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_general_comments(pr, opts, on_done)
	opts = opts or {}
	local slug = pr.repo_full_name or ""
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	-- Issue comments (also used for PRs)
	local endpoint = string.format("repos/%s/issues/%s/comments", slug, tostring(pr.id))
	return cli.tea({ endpoint }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local comments = {}
		for _, raw in ipairs(type(result) == "table" and result or {}) do
			local comment = mapper.to_comment(raw)
			if comment then
				table.insert(comments, comment)
			end
		end

		on_done(comments, nil)
	end, {
		action = "Fetch PR general comments",
		slug = slug,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_inline_comments(pr, opts, on_done)
	opts = opts or {}
	local slug = pr.repo_full_name or ""
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local endpoint = string.format("repos/%s/pulls/%s/comments", slug, tostring(pr.id))
	return cli.tea({ endpoint }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local comments = {}
		for _, raw in ipairs(type(result) == "table" and result or {}) do
			if type(raw) == "table" and raw.id ~= nil then
				local user = type(raw.user) == "table" and raw.user or {}
				local full_name = tostring(user.full_name or "")
				local login = tostring(user.login or "")
				local path = tostring(raw.path or "")
				local line = tonumber(raw.line or raw.new_position or raw.position) or 0
				table.insert(comments, {
					id = tostring(raw.id),
					parent_id = nil,
					content_raw = tostring(raw.body or ""),
					created_on = tostring(raw.created_at or ""),
					author = {
						name = full_name ~= "" and full_name or login,
						nickname = login,
						id = tostring(user.id or ""),
					},
					inline = path ~= "" and { path = path, to = line, from = line } or nil,
					_raw = raw,
				})
			end
		end

		on_done(comments, nil)
	end, {
		action = "Fetch PR inline comments",
		slug = slug,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(pr, opts, on_done)
	local slug = pr.repo_full_name or ""
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local general_result = nil
	local inline_result = nil
	local first_err = nil
	local pending = 2
	local cancelled = false
	local handles = {}

	local function finish()
		if cancelled then
			return
		end
		pending = pending - 1
		if pending > 0 then
			return
		end

		local all = {}
		for _, c in ipairs(general_result or {}) do
			table.insert(all, c)
		end
		for _, c in ipairs(inline_result or {}) do
			table.insert(all, c)
		end

		table.sort(all, function(a, b)
			return tostring(a.created_on or "") < tostring(b.created_on or "")
		end)

		on_done(all, first_err)
	end

	local function track(h)
		if h then
			table.insert(handles, h)
		end
	end

	track(M.fetch_general_comments(pr, opts, function(result, err)
		if err then
			first_err = first_err or err
		else
			general_result = result or {}
		end
		finish()
	end))

	track(M.fetch_inline_comments(pr, opts, function(result, err)
		if err then
			-- Inline comments may not exist on all Gitea instances; treat as empty
			inline_result = {}
		else
			inline_result = result or {}
		end
		finish()
	end))

	return {
		cancel = function()
			cancelled = true
			for _, h in ipairs(handles) do
				if h and h.cancel then
					h.cancel()
				end
			end
		end,
	}
end

---@param pr PullRequest
---@param content string
---@param opts PullsAddCommentOpts|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(pr, content, opts, on_done)
	opts = opts or {}
	local slug = pr.repo_full_name or ""
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	if opts.inline then
		-- Inline review comment
		local endpoint = string.format("repos/%s/pulls/%s/comments", slug, tostring(pr.id))
		local body = {
			body = content,
			path = opts.inline.path or "",
			new_position = opts.inline.line or 0,
		}
		return cli.api("POST", endpoint, body, function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Failed to create inline comment")
				return
			end
			on_done(mapper.to_comment(result), nil)
		end, {
			action = "Add inline comment",
			slug = slug,
			number = pr.id,
		})
	end

	-- General issue comment (works for PRs too)
	local endpoint = string.format("repos/%s/issues/%s/comments", slug, tostring(pr.id))
	return cli.api("POST", endpoint, { body = content }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to create comment")
			return
		end
		on_done(mapper.to_comment(result), nil)
	end, {
		action = "Add comment",
		slug = slug,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param comment PullsComment
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(pr, comment, on_done)
	local slug = pr.repo_full_name or ""
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local endpoint
	if comment.inline ~= nil then
		endpoint = string.format("repos/%s/pulls/comments/%s", slug, tostring(comment.id))
	else
		endpoint = string.format("repos/%s/issues/comments/%s", slug, tostring(comment.id))
	end

	return cli.api("PATCH", endpoint, { body = comment.content_raw }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to edit comment")
			return
		end
		on_done(mapper.to_comment(result), nil)
	end, {
		action = "Edit comment",
		slug = slug,
		comment_id = comment.id,
	})
end

---@param pr PullRequest
---@param target PullsComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(pr, target, on_done)
	local slug = pr.repo_full_name or ""
	if slug == "" then
		vim.schedule(function()
			on_done(false, "Missing repository info")
		end)
		return nil
	end

	local endpoint
	if target.inline ~= nil then
		endpoint = string.format("repos/%s/pulls/comments/%s", slug, tostring(target.id))
	else
		endpoint = string.format("repos/%s/issues/comments/%s", slug, tostring(target.id))
	end

	return cli.api("DELETE", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end, {
		action = "Delete comment",
		slug = slug,
		comment_id = target.id,
	})
end

return M
