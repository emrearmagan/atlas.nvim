local M = {}

local cli = require("atlas.providers.github.client").pulls
local json = require("atlas.core.json")
local mapper = require("atlas.pulls.providers.github.api.mapper")
local reviews = require("atlas.pulls.providers.github.api.reviews")

local REVIEW_COMMENT_FIELDS = [[
id
databaseId
body
diffHunk
url
createdAt
author { login ... on User { databaseId } ... on Bot { databaseId } }
pullRequestReview { id state commit { oid } }
]]

---@param pr PullRequest
---@param content string
---@param inline PullsInlineCommentPosition
---@param review_id string
---@param pending_review PullsReview|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function add_review_thread(pr, content, inline, review_id, pending_review, on_done)
	local side = inline.to and "RIGHT" or "LEFT"
	local line = inline.to or inline.from
	local query = ([[
mutation($reviewId:ID!,$path:String!,$body:String!,$line:Int!,$side:DiffSide!){
  addPullRequestReviewThread(input:{
    pullRequestReviewId:$reviewId
    path:$path
    body:$body
    line:$line
    side:$side
  }){
    thread{
      id
      isResolved
      isOutdated
      path
      line
      originalLine
      diffSide
      comments(last:1){nodes{%s}}
    }
  }
}
]]):format(REVIEW_COMMENT_FIELDS)
	local args = {
		"api",
		"graphql",
		"-f",
		"body=" .. content,
		"-f",
		"path=" .. inline.path,
		"-f",
		"side=" .. side,
		"-F",
		"line=" .. tostring(line),
	}
	vim.list_extend(args, { "-f", "reviewId=" .. review_id })
	vim.list_extend(args, { "-f", "query=" .. query })

	return cli.gh(args, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local data = result and result.data or {}
		local thread = data.addPullRequestReviewThread and data.addPullRequestReviewThread.thread
		local nodes = type(thread) == "table" and json.safe_table(thread.comments).nodes or {}
		local node = nodes[#nodes]
		if type(thread) ~= "table" or tostring(thread.id or "") == "" then
			on_done(nil, "GitHub did not return the created review thread")
			return
		end
		if type(node) ~= "table" or json.nilify(node.databaseId) == nil then
			on_done(nil, "GitHub did not return the created review comment")
			return
		end

		thread.path = thread.path or inline.path
		thread.diffSide = thread.diffSide or side
		if side == "LEFT" then
			thread.originalLine = thread.originalLine or line
		else
			thread.line = thread.line or line
		end
		local review = json.safe_table(node.pullRequestReview)
		reviews.update(pending_review, review)
		local created = mapper.to_review_comment(node, thread, nil)
		on_done(created, nil)
	end, {
		action = "Add pending comment",
		repo = pr.repo_full_name,
		number = pr.id,
		inline = true,
	})
end

---@param pr PullRequest
---@param content string
---@param inline PullsInlineCommentPosition
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function add_published_inline_comment(pr, content, inline, on_done)
	local commit_id = tostring(inline.commit_hash or pr.source.commit_hash or "")
	local side = inline.to and "RIGHT" or "LEFT"
	local line = inline.to or inline.from
	if commit_id == "" then
		vim.schedule(function()
			on_done(nil, "Missing source commit hash")
		end)
		return nil
	end

	return cli.gh({
		"api",
		"-X",
		"POST",
		string.format("repos/%s/pulls/%s/comments", pr.repo_full_name, tostring(pr.id)),
		"-f",
		"body=" .. content,
		"-f",
		"commit_id=" .. commit_id,
		"-f",
		"path=" .. inline.path,
		"-f",
		"side=" .. side,
		"-F",
		"line=" .. tostring(line),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to create inline comment")
			return
		end
		local created = mapper.to_comment(result)
		on_done(created, nil)
	end, {
		action = "Add comment",
		repo = pr.repo_full_name,
		number = pr.id,
		inline = true,
	})
end

local reply_comment

---@param pr PullRequest
---@param content string
---@param opts PullsAddCommentOpts|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(pr, content, opts, on_done)
	opts = opts or {}

	if opts.parent then
		return reply_comment(pr, opts.parent, content, opts, on_done)
	end

	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	if opts.inline then
		local commit_oid = tostring(opts.inline.commit_hash or pr.source.commit_hash or "")
		if not opts.pending then
			if opts.review and opts.review.pending then
				vim.schedule(function()
					on_done(nil, "Submit the pending review first")
				end)
				return nil
			end
			return add_published_inline_comment(pr, content, opts.inline, on_done)
		end
		return reviews.with_pending(pr, opts.review, commit_oid, function(review_id)
			return add_review_thread(pr, content, opts.inline, review_id, opts.review, on_done)
		end, function(err)
			on_done(nil, err)
		end)
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

local UPDATE_REVIEW_COMMENT_MUTATION = ([[
mutation($commentId:ID!,$body:String!){
  updatePullRequestReviewComment(input:{pullRequestReviewCommentId:$commentId,body:$body}){
    pullRequestReviewComment{%s}
  }
}
]]):format(REVIEW_COMMENT_FIELDS)

local DELETE_REVIEW_COMMENT_MUTATION = [[
mutation($commentId:ID!){
  deletePullRequestReviewComment(input:{id:$commentId}){
    pullRequestReview{id state commit{oid}}
  }
}
]]

---@param pr PullRequest
---@param comment PullsComment
---@param node_id string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function edit_pending_comment(pr, comment, node_id, on_done)
	return cli.gh({
		"api",
		"graphql",
		"-f",
		"commentId=" .. node_id,
		"-f",
		"body=" .. tostring(comment.content_raw or ""),
		"-f",
		"query=" .. UPDATE_REVIEW_COMMENT_MUTATION,
	}, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local data = json.safe_table(json.safe_table(result).data)
		local payload = json.safe_table(json.nilify(data.updatePullRequestReviewComment))
		local node = json.nilify(payload.pullRequestReviewComment)
		if type(node) ~= "table" or json.nilify(node.databaseId) == nil then
			on_done(nil, "GitHub did not return the updated comment")
			return
		end
		local updated = mapper.to_review_comment(node, mapper.review_thread(comment), comment.parent_id)
		updated.inline_hunk = updated.inline_hunk or comment.inline_hunk
		on_done(updated, nil)
	end, {
		action = "Edit comment",
		repo = pr.repo_full_name,
		number = pr.id,
		comment_id = comment.id,
	})
end

---@param pr PullRequest
---@param target PullsComment
---@param node_id string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function delete_pending_comment(pr, target, node_id, on_done)
	return cli.gh({
		"api",
		"graphql",
		"-f",
		"commentId=" .. node_id,
		"-f",
		"query=" .. DELETE_REVIEW_COMMENT_MUTATION,
	}, function(_, err)
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
		local body = tostring(comment.content_raw or "")
		return cli.gh({
			"pr",
			"edit",
			tostring(pr.id),
			"--repo",
			repo_slug,
			"--body",
			body,
		}, function(_, err)
			if err then
				on_done(nil, err)
				return
			end
			pr.description = body
			on_done(vim.tbl_extend("force", {}, comment, { content_raw = body }), nil)
		end, {
			action = "Edit comment",
			repo = pr.repo_full_name,
			number = pr.id,
			comment_id = comment.id,
		})
	end

	if comment.state == "PENDING" then
		local node_id = tostring((comment._raw or {}).comment_id or "")
		if node_id == "" then
			on_done(nil, "Missing review comment id")
			return nil
		end
		return edit_pending_comment(pr, comment, node_id, on_done)
	end

	local endpoint = comment.inline ~= nil
			and string.format("repos/%s/pulls/comments/%s", repo_slug, tostring(comment.id))
		or string.format("repos/%s/issues/comments/%s", repo_slug, tostring(comment.id))
	local body = tostring(comment.content_raw or "")

	return cli.api("PATCH", endpoint, { body = body }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to edit comment")
			return
		end
		local updated = mapper.to_comment(result)
		updated.state = comment.state
		updated.outdated = comment.outdated
		updated._raw = comment._raw
		on_done(updated, nil)
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

	if target.state == "PENDING" then
		local node_id = tostring((target._raw or {}).comment_id or "")
		if node_id == "" then
			on_done(false, "Missing review comment id")
			return nil
		end
		return delete_pending_comment(pr, target, node_id, on_done)
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

local SET_THREAD_RESOLVED_MUTATIONS = {
	resolve = [[
mutation($threadId:ID!){
  resolveReviewThread(input:{threadId:$threadId}){
    thread{id isResolved}
  }
}
]],
	reopen = [[
mutation($threadId:ID!){
  unresolveReviewThread(input:{threadId:$threadId}){
    thread{id isResolved}
  }
}
]],
}

---@param pr PullRequest
---@param root PullsComment
---@param resolved boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_thread_resolved(pr, root, resolved, on_done)
	local raw = root._raw or {}
	local thread_id = tostring(raw.thread_id or "")
	if thread_id == "" then
		vim.schedule(function()
			on_done(false, "Missing review thread id")
		end)
		return nil
	end

	return cli.gh({
		"api",
		"graphql",
		"-F",
		"threadId=" .. thread_id,
		"-f",
		"query=" .. SET_THREAD_RESOLVED_MUTATIONS[resolved and "resolve" or "reopen"],
	}, function(_, err)
		on_done(err == nil, err)
	end, {
		action = resolved and "Resolve review thread" or "Reopen review thread",
		repo = pr.repo_full_name,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param parent PullsComment
---@param content string
---@param opts PullsAddCommentOpts
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
reply_comment = function(pr, parent, content, opts, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	if parent.inline ~= nil then
		local pending = opts.pending == true
		local raw = parent._raw or {}
		local thread_id = tostring(raw.thread_id or "")
		if thread_id == "" then
			if pending then
				on_done(nil, "Missing review thread id")
				return nil
			end
			local root_id = parent.parent_id or parent.id
			return cli.api(
				"POST",
				string.format("repos/%s/pulls/%s/comments/%s/replies", repo_slug, tostring(pr.id), tostring(root_id)),
				{ body = content },
				function(result, err)
					if err or type(result) ~= "table" then
						on_done(nil, err or "Failed to create reply")
						return
					end
					local created = mapper.to_comment(result)
					created.parent_id = root_id
					created.inline_hunk = created.inline_hunk or parent.inline_hunk
					created.state = parent.state
					created.outdated = parent.outdated
					on_done(created, nil)
				end,
				{
					action = "Reply comment",
					repo = pr.repo_full_name,
					number = pr.id,
					parent_id = root_id,
				}
			)
		end

		local query = ([[
mutation($threadId:ID!,$reviewId:ID,$body:String!){
  addPullRequestReviewThreadReply(input:{
    pullRequestReviewThreadId:$threadId
    pullRequestReviewId:$reviewId
    body:$body
  }){
    comment{%s}
  }
}
]]):format(REVIEW_COMMENT_FIELDS)
		local function add_reply(review_id)
			local args = {
				"api",
				"graphql",
				"-f",
				"threadId=" .. thread_id,
				"-f",
				"body=" .. content,
			}
			if review_id ~= "" then
				vim.list_extend(args, { "-f", "reviewId=" .. review_id })
			end
			vim.list_extend(args, { "-f", "query=" .. query })

			return cli.gh(args, function(result, err)
				if err then
					on_done(nil, err)
					return
				end
				local data = result and result.data or {}
				local reply = data.addPullRequestReviewThreadReply and data.addPullRequestReviewThreadReply.comment
				if type(reply) ~= "table" or json.nilify(reply.databaseId) == nil then
					on_done(nil, "GitHub did not return the created reply")
					return
				end
				local review = json.safe_table(reply.pullRequestReview)
				reviews.update(opts.review, review)
				local created =
					mapper.to_review_comment(reply, mapper.review_thread(parent), parent.parent_id or parent.id)
				created.inline_hunk = created.inline_hunk or parent.inline_hunk
				on_done(created, nil)
			end, {
				action = "Reply comment",
				repo = pr.repo_full_name,
				number = pr.id,
				parent_id = parent.id,
			})
		end

		if pending then
			return reviews.with_pending(pr, opts.review, tostring(pr.source.commit_hash or ""), add_reply, function(err)
				on_done(nil, err)
			end)
		end
		return add_reply("")
	end

	return M.add_comment(pr, content, nil, on_done)
end

return M
