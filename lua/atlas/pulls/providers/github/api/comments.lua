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
---@param thread_state {resolved: boolean, outdated: boolean}|nil
---@return PullsComment
local function normalize_comment(raw, thread_state)
	local user = raw.user or {}
	local line = nilify(raw.line)
	local original_line = nilify(raw.original_line)
	local path = nilify(raw.path)

	local inline, inline_hunk
	if path ~= nil then
		local side = raw.side == "LEFT" and "old" or "new"
		local anchor = line or original_line
		inline = {
			path = tostring(path),
			to = side == "new" and anchor or nil,
			from = side == "old" and anchor or nil,
		}
		inline_hunk = parse_diff_hunk(raw.diff_hunk)
	end

	---@type "RESOLVED"|"OUTDATED"|nil
	local state = nil
	if thread_state ~= nil then
		if thread_state.resolved then
			state = "RESOLVED"
		elseif thread_state.outdated then
			state = "OUTDATED"
		end
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
		state = state,
		url = nil,
		html_url = tostring(raw.html_url or ""),
		reactions = reactions,
	}
end

local REVIEW_THREADS_QUERY = [[
query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      reviewThreads(first:100){
        nodes{
          isResolved
          isOutdated
          diffSide
          path
          line
          originalLine
          comments(first:100){
            nodes{
              databaseId
              body
              diffHunk
              url
              createdAt
              author{login ... on User{databaseId} ... on Bot{databaseId}}
              replyTo{databaseId}
              reactionGroups{content users{totalCount}}
            }
          }
        }
      }
    }
  }
}
]]

local REACTION_CONTENT_TO_KEY = {
	THUMBS_UP = "+1",
	THUMBS_DOWN = "-1",
	LAUGH = "laugh",
	HOORAY = "hooray",
	CONFUSED = "confused",
	HEART = "heart",
	ROCKET = "rocket",
	EYES = "eyes",
}

---@param gql_comment table
---@param thread table thread node providing path/line/diffSide
---@return table   REST-shaped raw comment that `normalize_comment` understands
local function gql_to_raw(gql_comment, thread)
	local author = nilify(gql_comment.author) or {}
	local reply_to = nilify(gql_comment.replyTo)

	local reactions = {}
	for _, group in ipairs(gql_comment.reactionGroups or {}) do
		local key = REACTION_CONTENT_TO_KEY[group.content or ""]
		if key and group.users then
			reactions[key] = tonumber(group.users.totalCount) or 0
		end
	end

	return {
		id = gql_comment.databaseId,
		in_reply_to_id = reply_to and reply_to.databaseId or nil,
		user = { login = author.login, id = author.databaseId },
		body = gql_comment.body,
		path = thread.path,
		diff_hunk = gql_comment.diffHunk,
		line = thread.line,
		original_line = thread.originalLine,
		side = thread.diffSide,
		url = gql_comment.url,
		html_url = gql_comment.url,
		created_at = gql_comment.createdAt,
		reactions = reactions,
	}
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(pr, opts, on_done)
	local repo_slug = pr.repo_full_name or ""
	local owner, name = tostring(repo_slug):match("^([^/]+)/([^/]+)$")
	if owner == nil or name == nil then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	return cli.gh({
		"api",
		"graphql",
		"-F",
		"owner=" .. owner,
		"-F",
		"name=" .. name,
		"-F",
		string.format("number=%s", tostring(pr.id)),
		"-f",
		"query=" .. REVIEW_THREADS_QUERY,
	}, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local threads = result
			and result.data
			and result.data.repository
			and result.data.repository.pullRequest
			and result.data.repository.pullRequest.reviewThreads
			and result.data.repository.pullRequest.reviewThreads.nodes
			or {}

		---@type PullsComment[]
		local out = {}
		for _, thread in ipairs(threads) do
			local thread_state = { resolved = thread.isResolved == true, outdated = thread.isOutdated == true }
			local nodes = thread.comments and thread.comments.nodes or {}
			for _, node in ipairs(nodes) do
				table.insert(out, normalize_comment(gql_to_raw(node, thread), thread_state))
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
