local M = {}

local cli = require("atlas.pulls.providers.github.api.cli")
local json = require("atlas.core.json")
local mapper = require("atlas.pulls.providers.github.api.mapper")

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
---@return table   REST-shaped raw comment that `mapper.to_comment` understands
local function gql_to_raw(gql_comment, thread)
	local author = json.nilify(gql_comment.author) or {}
	local reply_to = json.nilify(gql_comment.replyTo)

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
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(pr, _opts, on_done) ---@diagnostic disable-line: unused-local
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
				table.insert(out, mapper.to_comment(gql_to_raw(node, thread), thread_state))
			end
		end

		table.sort(out, function(a, b)
			return tostring(a.created_on or "") < tostring(b.created_on or "")
		end)
		on_done(out, nil)
	end, {
		action = "Fetch comments",
		repo = pr.repo_full_name,
		number = pr.id,
	})
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
			on_done(mapper.to_comment(result), nil)
		end, {
			action = "Add comment",
			repo = pr.repo_full_name,
			number = pr.id,
			inline = true,
		})
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
			on_done(mapper.to_comment(result), nil)
		end,
		{
			action = "Add comment",
			repo = pr.repo_full_name,
			number = pr.id,
			inline = false,
		}
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

	if tostring(comment.id) == "__body__" then
		return cli.gh({
			"pr", "edit", tostring(pr.id), "--repo", repo_slug, "--body", tostring(comment.content_raw or ""),
		}, function(_, err)
			if err then
				on_done(nil, err)
				return
			end
			on_done({
				id = "__body__",
				parent_id = nil,
				author = comment.author,
				content_raw = tostring(comment.content_raw or ""),
				created_on = comment.created_on or pr.created_on or "",
			}, nil)
		end, {
			action = "Edit comment",
			repo = pr.repo_full_name,
			number = pr.id,
			comment_id = comment.id,
		})
	end

	local endpoint = comment.inline ~= nil
			and string.format("repos/%s/pulls/comments/%s", repo_slug, tostring(comment.id))
		or string.format("repos/%s/issues/comments/%s", repo_slug, tostring(comment.id))

	return cli.api("PATCH", endpoint, { body = comment.content_raw }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to edit comment")
			return
		end
		on_done(mapper.to_comment(result), nil)
	end, {
		action = "Edit comment",
		repo = pr.repo_full_name,
		number = pr.id,
		comment_id = comment.id,
	})
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

	if tostring(target.id) == "__body__" then
		vim.schedule(function()
			on_done(false, "Cannot delete the pull request description")
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
	end, {
		action = "Delete comment",
		repo = pr.repo_full_name,
		number = pr.id,
		comment_id = target.id,
	})
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
				on_done(mapper.to_comment(result), nil)
			end,
			{
				action = "Reply comment",
				repo = pr.repo_full_name,
				number = pr.id,
				parent_id = parent.id,
			}
		)
	end

	return M.add_comment(pr, content, nil, on_done)
end

return M
