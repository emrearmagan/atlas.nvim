local M = {}

local cli = require("atlas.providers.github.client").pulls
local json = require("atlas.core.json")
local mapper = require("atlas.pulls.providers.github.api.mapper")
local github_mapping = require("atlas.providers.github.mapping")

local REVIEW_QUERY = [[
query($owner:String!,$name:String!,$number:Int!,$endCursor:String){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      id
      reviews(first:100,states:[PENDING]){
        nodes{id state commit{oid}}
      }
      reviewThreads(first:100,after:$endCursor){
        pageInfo{hasNextPage endCursor}
        nodes{
          id
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
              pullRequestReview{id state}
              reactionGroups{content users{totalCount}}
            }
          }
        }
      }
    }
  }
}
]]

local REVIEW_COMMENT_FIELDS = [[
databaseId
body
diffHunk
url
createdAt
author { login ... on User { databaseId } ... on Bot { databaseId } }
pullRequestReview { id state commit { oid } }
]]

---@param line string
---@return string|nil
local function checkbox_marker(line)
	return line:match("^%s*[-*+]%s+%[([ xX])%]") or line:match("^%s*%[([ xX])%]")
end

---@param raw table
---@return PullsComment[]
local function to_tasks(raw)
	local out = {}
	for _, line in ipairs(vim.split(tostring(raw.body or ""), "\n", { plain = true })) do
		local marker = checkbox_marker(line)
		if marker then
			local comment = mapper.to_comment(raw)
			local index = #out + 1
			comment.id = string.format("github-task:%s:%06d", tostring(raw.id), index)
			comment.content_raw = line
			comment.is_task = true
			comment.task_label = "Checklist"
			comment.state = marker:lower() == "x" and "RESOLVED" or nil
			table.insert(out, comment)
		end
	end
	return out
end

---@param comments PullsComment[]
local function normalize_inline_hunks(comments)
	local longest = {}
	for _, comment in ipairs(comments) do
		local inline = comment.inline
		local hunk = comment.inline_hunk
		if inline and hunk then
			local key = string.format("%s|%d|%d", inline.path, hunk.old_start, hunk.new_start)
			if not longest[key] or #hunk.lines > #longest[key].lines then
				longest[key] = hunk
			end
		end
	end
	for _, comment in ipairs(comments) do
		local inline = comment.inline
		local hunk = comment.inline_hunk
		if inline and hunk then
			local key = string.format("%s|%d|%d", inline.path, hunk.old_start, hunk.new_start)
			comment.inline_hunk = longest[key]
		end
	end
end

---@param gql_comment table
---@param thread table thread node providing path/line/diffSide
---@return table   REST-shaped raw comment that `mapper.to_comment` understands
local function gql_to_raw(gql_comment, thread)
	local author = json.nilify(gql_comment.author) or {}
	local reply_to = json.nilify(gql_comment.replyTo)

	return {
		id = gql_comment.databaseId,
		in_reply_to_id = reply_to and reply_to.databaseId or nil,
		user = { login = author.login, id = author.databaseId },
		body = gql_comment.body,
		path = thread.path or gql_comment.path,
		diff_hunk = gql_comment.diffHunk,
		line = thread.line or gql_comment.line,
		original_line = thread.originalLine or gql_comment.originalLine,
		side = thread.diffSide,
		url = gql_comment.url,
		html_url = gql_comment.url,
		created_at = gql_comment.createdAt,
		reactions = github_mapping.reaction_groups(gql_comment.reactionGroups),
	}
end

---@param connection table|nil
---@return table|nil
local function last_node(connection)
	local nodes = json.nilify(json.safe_table(connection).nodes) or {}
	return nodes[#nodes]
end

---@param node table
---@param thread table
---@param fallback_parent number|string|nil
---@return PullsComment
local function to_review_comment(node, thread, fallback_parent)
	local review = json.safe_table(node.pullRequestReview)
	local comment = mapper.to_comment(gql_to_raw(node, thread), {
		pending = review.state == "PENDING",
		resolved = thread.isResolved == true,
		outdated = thread.isOutdated == true,
	})
	comment._raw = {
		thread_id = tostring(thread.id or ""),
		review_id = tostring(review.id or ""),
	}
	if comment.parent_id == nil then
		comment.parent_id = fallback_parent
	end
	return comment
end

---@param pr PullRequest
---@param review table
local function remember_pending_review(pr, review)
	if review.state ~= "PENDING" or tostring(review.id or "") == "" then
		return
	end
	pr._raw.reviews = {
		nodes = { { id = review.id, state = review.state, commit = review.commit } },
	}
end

---@param pr PullRequest
---@return string|nil
local function pending_review_id(pr)
	for _, review in ipairs(json.safe_table(pr._raw.reviews).nodes or {}) do
		if review.state == "PENDING" and tostring(review.id or "") ~= "" then
			return tostring(review.id)
		end
	end
	return nil
end

local SUBMIT_REVIEW_MUTATION = [[
mutation($reviewId:ID!,$event:PullRequestReviewEvent!,$body:String){
  submitPullRequestReview(input:{pullRequestReviewId:$reviewId,event:$event,body:$body}){
    pullRequestReview{id state}
  }
}
]]

---@param pr PullRequest
---@param review_id string
---@param event string
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function submit_pending_review(pr, review_id, event, body, on_done)
	return cli.gh({
		"api",
		"graphql",
		"-f",
		"reviewId=" .. review_id,
		"-f",
		"event=" .. event,
		"-f",
		"body=" .. body,
		"-f",
		"query=" .. SUBMIT_REVIEW_MUTATION,
	}, function(result, err)
		if err then
			on_done(false, err)
			return
		end
		local review = (((result or {}).data or {}).submitPullRequestReview or {}).pullRequestReview
		if type(review) ~= "table" or tostring(review.id or "") == "" then
			on_done(false, "GitHub did not return the submitted review")
			return
		end
		pr._raw.reviews = nil
		on_done(true, nil)
	end, {
		action = "Submit review",
		repo = pr.repo_full_name,
		number = pr.id,
	})
end

local CREATE_REVIEW_MUTATION = [[
mutation($pullRequestId:ID!,$event:PullRequestReviewEvent!,$body:String){
  addPullRequestReview(input:{pullRequestId:$pullRequestId,event:$event,body:$body}){
    pullRequestReview{id state}
  }
}
]]

---@param pr PullRequest
---@param pull_request_id string
---@param event string
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function create_review(pr, pull_request_id, event, body, on_done)
	return cli.gh({
		"api",
		"graphql",
		"-f",
		"pullRequestId=" .. pull_request_id,
		"-f",
		"event=" .. event,
		"-f",
		"body=" .. body,
		"-f",
		"query=" .. CREATE_REVIEW_MUTATION,
	}, function(result, err)
		if err then
			on_done(false, err)
			return
		end
		local review = (((result or {}).data or {}).addPullRequestReview or {}).pullRequestReview
		if type(review) ~= "table" or tostring(review.id or "") == "" then
			on_done(false, "GitHub did not return the submitted review")
			return
		end
		pr._raw.reviews = nil
		on_done(true, nil)
	end, {
		action = "Submit review",
		repo = pr.repo_full_name,
		number = pr.id,
	})
end

local PENDING_REVIEW_QUERY = [[
query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      id
      reviews(first:1,states:[PENDING]){nodes{id state}}
    }
  }
}
]]

---@param pr PullRequest
---@param event "COMMENT"|"APPROVE"|"REQUEST_CHANGES"
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function finish_review(pr, event, body, on_done)
	local known_review = pending_review_id(pr)
	if known_review then
		return submit_pending_review(pr, known_review, event, body, on_done)
	end

	local owner, name = pr.repo_full_name:match("^([^/]+)/([^/]+)$")
	if owner == nil or name == nil then
		vim.schedule(function()
			on_done(false, "Missing repo")
		end)
		return nil
	end

	local cancelled = false
	local current = cli.gh({
		"api",
		"graphql",
		"-f",
		"owner=" .. owner,
		"-f",
		"name=" .. name,
		"-F",
		"number=" .. tostring(pr.id),
		"-f",
		"query=" .. PENDING_REVIEW_QUERY,
	}, function(result, err)
		if cancelled then
			return
		end
		if err then
			on_done(false, err)
			return
		end
		local pull_request = (((result or {}).data or {}).repository or {}).pullRequest
		if type(pull_request) ~= "table" or tostring(pull_request.id or "") == "" then
			on_done(false, "GitHub did not return the pull request")
			return
		end
		local review_id
		for _, review in ipairs(json.safe_table(pull_request.reviews).nodes or {}) do
			if review.state == "PENDING" and tostring(review.id or "") ~= "" then
				review_id = tostring(review.id)
				break
			end
		end
		current = review_id and submit_pending_review(pr, review_id, event, body, on_done)
			or create_review(pr, tostring(pull_request.id), event, body, on_done)
		if cancelled and current then
			current.cancel()
		end
	end, {
		action = "Find pending review",
		repo = pr.repo_full_name,
		number = pr.id,
	})
	return {
		cancel = function()
			cancelled = true
			if current then
				current.cancel()
			end
		end,
	}
end

---@param pr PullRequest
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.submit_review(pr, body, on_done)
	return finish_review(pr, "COMMENT", body, on_done)
end

---@param pr PullRequest
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.approve_review(pr, on_done)
	return finish_review(pr, "APPROVE", "", on_done)
end

---@param pr PullRequest
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.request_changes_review(pr, body, on_done)
	return finish_review(pr, "REQUEST_CHANGES", body, on_done)
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(pr, _opts, on_done)
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
		"--paginate",
		"--slurp",
		"-F",
		"owner=" .. owner,
		"-F",
		"name=" .. name,
		"-F",
		string.format("number=%s", tostring(pr.id)),
		"-f",
		"query=" .. REVIEW_QUERY,
	}, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		if type(result) ~= "table" then
			on_done(nil, "Missing pull request review data")
			return
		end

		local pull_request
		local threads = {}
		for _, page in ipairs(result) do
			local data = type(page) == "table" and page.data or nil
			local page_pr = data and data.repository and data.repository.pullRequest
			if type(page_pr) ~= "table" then
				on_done(nil, "Missing pull request review data")
				return
			end
			pull_request = pull_request or page_pr
			vim.list_extend(threads, (page_pr.reviewThreads or {}).nodes or {})
		end
		if pull_request == nil then
			on_done(nil, "Missing pull request review data")
			return
		end
		local raw = pr._raw
		raw.node_id = tostring(pull_request.id or "")
		raw.reviews = pull_request.reviews

		---@type PullsComment[]
		local out = {}
		for _, thread in ipairs(threads) do
			local nodes = thread.comments and thread.comments.nodes or {}
			for index, node in ipairs(nodes) do
				local root_id = index > 1 and nodes[1] and nodes[1].databaseId or nil
				local comment = to_review_comment(node, thread, root_id)
				table.insert(out, comment)
			end
		end
		normalize_inline_hunks(out)

		table.sort(out, function(a, b)
			local left = tostring(a.created_on or "")
			local right = tostring(b.created_on or "")
			return left == right and tostring(a.id) < tostring(b.id) or left < right
		end)
		on_done(out, nil)
	end, {
		action = "Fetch comments",
		repo = pr.repo_full_name,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(tasks: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_tasks(pr, _opts, on_done)
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
		"--slurp",
		string.format("repos/%s/issues/%s/comments?per_page=100", repo_slug, tostring(pr.id)),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Missing pull request checklist data")
			return
		end

		---@type PullsComment[]
		local out = {}
		for _, page in ipairs(result) do
			for _, raw in ipairs(type(page) == "table" and page or {}) do
				for _, task in ipairs(to_tasks(raw)) do
					table.insert(out, task)
				end
			end
		end
		table.sort(out, function(a, b)
			local left = tostring(a.created_on or "")
			local right = tostring(b.created_on or "")
			return left == right and tostring(a.id) < tostring(b.id) or left < right
		end)
		on_done(out, nil)
	end, {
		action = "Fetch checklists",
		repo = pr.repo_full_name,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param content string
---@param inline PullsInlineCommentPosition
---@param review_id string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function add_review_thread(pr, content, inline, review_id, on_done)
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
		local node = type(thread) == "table" and last_node(thread.comments) or nil
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
		remember_pending_review(pr, review)
		local created = to_review_comment(node, thread, nil)
		if tostring(created._raw.review_id or "") == "" then
			created._raw.review_id = review_id
		end
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
		created.can_resolve = false
		on_done(created, nil)
	end, {
		action = "Add comment",
		repo = pr.repo_full_name,
		number = pr.id,
		inline = true,
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
		local raw = pr._raw
		local reviews = json.safe_table(raw.reviews).nodes or {}
		local pending_review = reviews[1]
		local review_id = tostring((pending_review or {}).id or "")
		local commit_oid = tostring(opts.inline.commit_hash or pr.source.commit_hash or "")
		local pending_commit = tostring(((pending_review or {}).commit or {}).oid or "")
		if
			opts.pending
			and review_id ~= ""
			and commit_oid ~= ""
			and pending_commit ~= ""
			and commit_oid ~= pending_commit
		then
			vim.schedule(function()
				on_done(nil, "Pending review belongs to a different commit")
			end)
			return nil
		end
		if not opts.pending then
			if review_id ~= "" then
				vim.schedule(function()
					on_done(nil, "Submit the pending review first")
				end)
				return nil
			end
			return add_published_inline_comment(pr, content, opts.inline, on_done)
		end
		if review_id ~= "" then
			return add_review_thread(pr, content, opts.inline, review_id, on_done)
		end

		local pull_request_id = github_mapping.node_id(raw) or ""
		if pull_request_id == "" then
			vim.schedule(function()
				on_done(nil, "Missing pull request node id")
			end)
			return nil
		end

		local cancelled = false
		local current
		local query = [[
mutation($pullRequestId:ID!,$commitOID:GitObjectID){
  addPullRequestReview(input:{pullRequestId:$pullRequestId commitOID:$commitOID}){
    pullRequestReview{id state commit{oid}}
  }
}
]]
		local args = {
			"api",
			"graphql",
			"-f",
			"pullRequestId=" .. pull_request_id,
			"-f",
			"query=" .. query,
		}
		if commit_oid ~= "" then
			vim.list_extend(args, { "-f", "commitOID=" .. commit_oid })
		end
		current = cli.gh(args, function(result, err)
			if cancelled then
				return
			end
			if err then
				on_done(nil, err)
				return
			end
			local data = result and result.data or {}
			local review = data.addPullRequestReview and data.addPullRequestReview.pullRequestReview
			if type(review) ~= "table" or tostring(review.id or "") == "" then
				on_done(nil, "GitHub did not return the pending review")
				return
			end
			remember_pending_review(pr, review)
			current = add_review_thread(pr, content, opts.inline, tostring(review.id), on_done)
			if cancelled and current then
				current.cancel()
			end
		end, {
			action = "Create pending review",
			repo = pr.repo_full_name,
			number = pr.id,
		})
		return {
			cancel = function()
				cancelled = true
				if current then
					current.cancel()
				end
			end,
		}
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
			"pr",
			"edit",
			tostring(pr.id),
			"--repo",
			repo_slug,
			"--body",
			tostring(comment.content_raw or ""),
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
	local body = tostring(comment.content_raw or "")

	return cli.api("PATCH", endpoint, { body = body }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to edit comment")
			return
		end
		local updated = mapper.to_comment(result)
		updated.state = comment.state
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
		local raw = parent._raw or {}
		local thread_id = tostring(raw.thread_id or "")
		if thread_id == "" then
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
					created.can_resolve = false
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

		local review_id = parent.state == "PENDING" and tostring(raw.review_id or "") or ""
		if parent.state == "PENDING" and review_id == "" then
			vim.schedule(function()
				on_done(nil, "Missing pending review id")
			end)
			return nil
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
			local inline = parent.inline or {}
			local review = json.safe_table(reply.pullRequestReview)
			remember_pending_review(pr, review)
			local created = to_review_comment(reply, {
				id = thread_id,
				path = inline.path,
				line = inline.to,
				originalLine = inline.from,
				diffSide = inline.from ~= nil and "LEFT" or "RIGHT",
				isResolved = parent.state == "RESOLVED",
				isOutdated = parent.state == "OUTDATED",
			}, parent.parent_id or parent.id)
			created.inline_hunk = created.inline_hunk or parent.inline_hunk
			on_done(created, nil)
		end, {
			action = "Reply comment",
			repo = pr.repo_full_name,
			number = pr.id,
			parent_id = parent.id,
		})
	end

	return M.add_comment(pr, content, nil, on_done)
end

return M
