local M = {}

local cli = require("atlas.providers.github.client")
local json = require("atlas.core.json")
local mapper = require("atlas.pulls.providers.github.api.mapper")
local reviews = require("atlas.pulls.providers.github.api.reviews")
local request_scope = require("atlas.core.requests")

local REVIEW_COMMENT_FIELDS = [[
id
databaseId
body
url
createdAt
author { login ... on User { databaseId } ... on Bot { databaseId } }
reactionGroups { content users { totalCount } }
pullRequestReview { id state commit { oid } }
]]

local ADD_REVIEW_THREAD_MUTATION = ([[
mutation($reviewId:ID!,$path:String!,$body:String!,$subjectType:PullRequestReviewThreadSubjectType!,$line:Int,$side:DiffSide,$startLine:Int,$startSide:DiffSide){
  addPullRequestReviewThread(input:{
    pullRequestReviewId:$reviewId
    path:$path
    body:$body
    subjectType:$subjectType
    line:$line
    side:$side
    startLine:$startLine
    startSide:$startSide
  }){
    thread{
      id
      isResolved
      isOutdated
      subjectType
      path
      line
      startLine
      originalLine
      originalStartLine
      diffSide
      startDiffSide
      comments(last:1){nodes{%s}}
    }
  }
}
]]):format(REVIEW_COMMENT_FIELDS)

---@param pr PullRequest
---@param content string
---@param target PullsInlineCommentPosition|PullsFileCommentPosition
---@param file_level boolean
---@param review_id string
---@param pending_review PullsReview|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function add_review_thread(pr, content, target, file_level, review_id, pending_review, on_done)
	local side = not file_level and (target.to and "RIGHT" or "LEFT") or nil
	local line = not file_level and (target.to or target.from) or nil
	local start_line = not file_level and (side == "RIGHT" and target.start_to or target.start_from) or nil
	local args = {
		"api",
		"graphql",
		"-f",
		"body=" .. content,
		"-f",
		"path=" .. target.path,
		"-f",
		"subjectType=" .. (file_level and "FILE" or "LINE"),
	}
	if not file_level then
		vim.list_extend(args, { "-f", "side=" .. side, "-F", "line=" .. tostring(line) })
		if start_line then
			vim.list_extend(args, { "-F", "startLine=" .. tostring(start_line), "-f", "startSide=" .. side })
		end
	end
	vim.list_extend(args, { "-f", "reviewId=" .. review_id })
	vim.list_extend(args, { "-f", "query=" .. ADD_REVIEW_THREAD_MUTATION })

	return cli.gh(args, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to create review thread")
			return
		end

		local payload = json.nilify(result.data.addPullRequestReviewThread)
		local thread = payload and json.nilify(payload.thread)
		if not thread or tostring(thread.id or "") == "" then
			on_done(nil, "GitHub did not return the created review thread")
			return
		end
		local nodes = json.safe_table(json.safe_table(thread.comments).nodes)
		local node = json.nilify(nodes[#nodes])
		if not node or json.nilify(node.databaseId) == nil then
			on_done(nil, "GitHub did not return the created review comment")
			return
		end

		thread.path = thread.path or target.path
		thread.subjectType = thread.subjectType or (file_level and "FILE" or "LINE")
		thread.diffSide = thread.diffSide or side
		if side == "LEFT" then
			thread.originalLine = thread.originalLine or line
			thread.originalStartLine = thread.originalStartLine or start_line
		elseif side == "RIGHT" then
			thread.line = thread.line or line
			thread.startLine = thread.startLine or start_line
		end
		thread.startDiffSide = thread.startDiffSide or (start_line and side or nil)
		local review = json.safe_table(node.pullRequestReview)
		reviews.update(pending_review, review)
		local created = mapper.to_review_comment(node, thread, nil)
		on_done(created, nil)
	end, {
		action = "Add pending comment",
		repo = pr.repo_full_name,
		number = pr.id,
		inline = not file_level,
	})
end

---@param pr PullRequest
---@param review PullsReview|nil
---@param commit_oid string
---@param add_comment fun(review_id: string, done: fun(comment: PullsComment|nil, err: string|nil)): { cancel: fun() }|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }
local function publish_comment(pr, review, commit_oid, add_comment, on_done)
	local pending_review = review or { pending = false }
	local requests = request_scope.new()
	requests.run(function(done)
		return reviews.create_pending(pr, pending_review, commit_oid, done)
	end, function(review_id, err)
		if err then
			on_done(nil, err)
			return
		end
		requests.run(function(done)
			return add_comment(review_id, done)
		end, function(created, create_err)
			if create_err then
				on_done(nil, create_err)
				return
			end
			requests.run(function(done)
				return reviews.submit(pr, { id = review_id, pending = true }, "", done)
			end, function(ok, submit_err)
				if not ok then
					on_done(
						nil,
						"Comment saved as pending; refresh and submit the review: "
							.. (submit_err or "Failed to publish comment")
					)
					return
				end
				reviews.update(pending_review, nil)
				created.state = created.outdated and "OUTDATED" or nil
				on_done(created, nil)
			end)
		end)
	end)
	return requests
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

	local target = opts.inline or opts.file
	if target then
		local file_level = opts.file ~= nil
		local commit_oid = tostring(target.commit_hash or pr.source.commit_hash or "")
		if not opts.pending then
			return publish_comment(pr, opts.review, commit_oid, function(review_id, done)
				return add_review_thread(pr, content, target, file_level, review_id, nil, done)
			end, on_done)
		end
		return reviews.with_pending(pr, opts.review, commit_oid, function(review_id)
			return add_review_thread(pr, content, target, file_level, review_id, opts.review, on_done)
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
    clientMutationId
  }
}
]]

---@param pr PullRequest
---@param comment PullsComment
---@param node_id string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function edit_review_comment(pr, comment, node_id, on_done)
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
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to update comment")
			return
		end
		local data = json.safe_table(result.data)
		local payload = json.safe_table(json.nilify(data.updatePullRequestReviewComment))
		local node = json.nilify(payload.pullRequestReviewComment)
		if not node or json.nilify(node.databaseId) == nil then
			on_done(nil, "GitHub did not return the updated comment")
			return
		end
		local updated = mapper.to_review_comment(node, mapper.review_thread(comment), comment.parent_id)
		updated.resolved_by = comment.resolved_by
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
local function delete_review_comment(pr, target, node_id, on_done)
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

	if comment.inline or comment.file or comment.state == "PENDING" then
		local node_id = tostring((comment._raw or {}).comment_id or "")
		if node_id == "" then
			on_done(nil, "Missing review comment id")
			return nil
		end
		return edit_review_comment(pr, comment, node_id, on_done)
	end

	local endpoint = string.format("repos/%s/issues/comments/%s", repo_slug, tostring(comment.id))
	local body = tostring(comment.content_raw or "")

	return cli.api("PATCH", endpoint, { body = body }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to edit comment")
			return
		end
		local updated = mapper.to_comment(result)
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

	if target.inline or target.file or target.state == "PENDING" then
		local node_id = tostring((target._raw or {}).comment_id or "")
		if node_id == "" then
			on_done(false, "Missing review comment id")
			return nil
		end
		return delete_review_comment(pr, target, node_id, on_done)
	end

	local endpoint = string.format("repos/%s/issues/comments/%s", repo_slug, tostring(target.id))

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
	local thread_id = tostring(root.thread_id or "")
	if thread_id == "" then
		vim.schedule(function()
			on_done(false, "Missing review thread id")
		end)
		return nil
	end

	return cli.gh({
		"api",
		"graphql",
		"-f",
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

local ADD_REVIEW_REPLY_MUTATION = ([[
mutation($threadId:ID!,$reviewId:ID!,$body:String!){
  addPullRequestReviewThreadReply(input:{
    pullRequestReviewThreadId:$threadId
    pullRequestReviewId:$reviewId
    body:$body
  }){
    comment{%s}
  }
}
]]):format(REVIEW_COMMENT_FIELDS)

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

	if parent.inline ~= nil or parent.file ~= nil then
		local pending = opts.pending == true
		local thread_id = tostring(parent.thread_id or "")
		if thread_id == "" then
			on_done(nil, "Missing review thread id")
			return nil
		end

		local function add_reply(review_id, done)
			local args = {
				"api",
				"graphql",
				"-f",
				"threadId=" .. thread_id,
				"-f",
				"body=" .. content,
				"-f",
				"reviewId=" .. review_id,
				"-f",
				"query=" .. ADD_REVIEW_REPLY_MUTATION,
			}

			return cli.gh(args, function(result, err)
				if err or type(result) ~= "table" then
					done(nil, err or "Failed to create reply")
					return
				end
				local payload = json.nilify(result.data.addPullRequestReviewThreadReply)
				local reply = payload and json.nilify(payload.comment)
				if not reply or json.nilify(reply.databaseId) == nil then
					done(nil, "GitHub did not return the created reply")
					return
				end
				local review = json.safe_table(reply.pullRequestReview)
				if pending then
					reviews.update(opts.review, review)
				end
				local created =
					mapper.to_review_comment(reply, mapper.review_thread(parent), parent.parent_id or parent.id)
				done(created, nil)
			end, {
				action = "Reply comment",
				repo = pr.repo_full_name,
				number = pr.id,
				parent_id = parent.id,
			})
		end

		if pending then
			return reviews.with_pending(pr, opts.review, pr.source.commit_hash, function(review_id)
				return add_reply(review_id, on_done)
			end, function(err)
				on_done(nil, err)
			end)
		end
		return publish_comment(pr, opts.review, pr.source.commit_hash, add_reply, function(created, err)
			if created and parent.state == "RESOLVED" then
				created.state = "RESOLVED"
			end
			on_done(created, err)
		end)
	end

	return M.add_comment(pr, content, nil, on_done)
end

return M
