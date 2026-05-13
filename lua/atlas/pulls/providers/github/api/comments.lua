local M = {}

local cli = require("atlas.pulls.providers.github.api.cli")
local diff_parser = require("atlas.core.git.diff_parser")

local function nilify(value)
	if value == nil or value == vim.NIL then
		return nil
	end
	return value
end

---@param diff_hunk string|nil
---@return DiffHunk|nil
local function parse_diff_hunk(diff_hunk)
	if type(diff_hunk) ~= "string" or diff_hunk == "" then
		return nil
	end
	-- GitHub returns just the @@ snippet but the parser expects a full git-format so we simply wrap it because i am too lazy to rethink this
	local synthetic = "diff --git a/x b/x\n--- a/x\n+++ b/x\n" .. diff_hunk .. "\n"
	local files = diff_parser.parse(synthetic)
	if #files == 0 or #files[1].hunks == 0 then
		return nil
	end

	return files[1].hunks[1]
end

---@param raw table
---@return PullsComment
local function normalize_comment(raw)
	local user = raw.user or {}
	local line = nilify(raw.line)
	local path = nilify(raw.path)

	local inline, inline_hunk
	if path ~= nil then
		local side = raw.side == "LEFT" and "old" or "new"
		inline = {
			path = tostring(path),
			to = side == "new" and line or nil,
			from = side == "old" and line or nil,
			outdated = line == nil,
		}
		inline_hunk = parse_diff_hunk(raw.diff_hunk)
	end

	local reactions
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
		parent_id = nilify(raw.in_reply_to_id),
		author = {
			name = tostring(user.login or ""),
			nickname = tostring(user.login or ""),
			id = tostring(user.id or ""),
		},
		content_raw = tostring(raw.body or ""),
		created_on = tostring(raw.created_at or ""),
		inline = inline,
		inline_hunk = inline_hunk,
		is_task = nil,
		state = nil,
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

	return cli.gh({
		"api",
		"--paginate",
		string.format("repos/%s/pulls/%s/comments?per_page=100", repo_slug, tostring(pr.id)),
	}, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local out = {}
		if type(result) == "table" then
			for _, raw in ipairs(result) do
				table.insert(out, normalize_comment(raw))
			end
		end
		table.sort(out, function(a, b)
			return tostring(a.created_on or "") < tostring(b.created_on or "")
		end)
		on_done(out, nil)
	end)
end

---@param pr PullRequest
---@param content string
---@param opts PullsAddCommentOpts|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(pr, content, opts, on_done)
	opts = opts or {}

	if opts.parent then
		return M.reply_comment(pr, opts.parent, content, on_done)
	end

	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	if opts.inline then
		local commit_id = tostring(pr.source and pr.source.commit_hash or "")
		if commit_id == "" then
			vim.schedule(function()
				on_done(nil, "Missing source commit hash")
			end)
			return nil
		end
		local side = opts.inline.side == "old" and "LEFT" or "RIGHT"
		return cli.gh({
			"api",
			"-X",
			"POST",
			string.format("repos/%s/pulls/%s/comments", repo_slug, tostring(pr.id)),
			"-f",
			"body=" .. content,
			"-f",
			"commit_id=" .. commit_id,
			"-f",
			"path=" .. opts.inline.path,
			"-f",
			"side=" .. side,
			"-F",
			"line=" .. tostring(opts.inline.line),
		}, function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Failed to create inline comment")
				return
			end
			on_done(normalize_comment(result), nil)
		end)
	end

	-- GitHub has no native task concept like bitbuckett does opts.is_task is ignored.
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
---@param comment PullsComment
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(pr, comment, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local endpoint = comment.inline ~= nil
			and string.format("repos/%s/pulls/comments/%s", repo_slug, tostring(comment.id))
		or string.format("repos/%s/issues/comments/%s", repo_slug, tostring(comment.id))

	return cli.api("PATCH", endpoint, { body = comment.content_raw }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to edit comment")
			return
		end
		on_done(normalize_comment(result), nil)
	end)
end

---@param pr PullRequest
---@param target PullsComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(pr, target, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(false, "Missing repo")
		end)
		return nil
	end

	local endpoint = target.inline ~= nil
			and string.format("repos/%s/pulls/comments/%s", repo_slug, tostring(target.id))
		or string.format("repos/%s/issues/comments/%s", repo_slug, tostring(target.id))

	return cli.api("DELETE", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param parent PullsComment
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.reply_comment(pr, parent, content, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	if parent.inline ~= nil then
		return cli.api(
			"POST",
			string.format("repos/%s/pulls/%s/comments/%s/replies", repo_slug, tostring(pr.id), tostring(parent.id)),
			{ body = content },
			function(result, err)
				if err or type(result) ~= "table" then
					on_done(nil, err or "Failed to reply")
					return
				end
				on_done(normalize_comment(result), nil)
			end
		)
	end

	return M.add_comment(pr, content, nil, on_done)
end

return M
