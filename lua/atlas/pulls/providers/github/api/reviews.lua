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
          subjectType
          diffSide
          startDiffSide
          path
          line
          startLine
          originalLine
          originalStartLine
          comments(first:100){
            nodes{
              id
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

local REVIEW_CONTEXT_QUERY = [[
query($owner:String!,$repo:String!,$number:Int!,$endCursor:String){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$number){
      id
      assignees(first:100){nodes{id login name}}
      reviews(first:100){nodes{author{login}}}
      reviewRequests(first:100){nodes{requestedReviewer{... on User{id login name}}}}
      files(first:100,after:$endCursor){
        pageInfo{hasNextPage endCursor}
        nodes{path viewerViewedState}
      }
    }
  }
}
]]

local SET_FILE_REVIEWED_MUTATIONS = {
	[true] = [[
mutation($pullRequestId:ID!,$path:String!){
  markFileAsViewed(input:{pullRequestId:$pullRequestId,path:$path}){clientMutationId}
}
]],
	[false] = [[
mutation($pullRequestId:ID!,$path:String!){
  unmarkFileAsViewed(input:{pullRequestId:$pullRequestId,path:$path}){clientMutationId}
}
]],
}

---@param node table|nil
---@return PullsReview
local function from_node(node)
	return {
		id = node and tostring(node.id or "") ~= "" and tostring(node.id) or nil,
		commit_hash = node and tostring((node.commit or {}).oid or "") ~= "" and tostring(node.commit.oid) or nil,
		pending = node ~= nil and node.state == "PENDING",
	}
end

---@param review PullsReview|nil
---@param node table|nil
function M.update(review, node)
	if not review then
		return
	end
	local value = from_node(node)
	review.id = value.id
	review.commit_hash = value.commit_hash
	review.pending = value.pending
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
local function submit_pending(pr, review_id, event, body, on_done)
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
local function create(pr, pull_request_id, event, body, on_done)
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
      reviews(first:1,states:[PENDING]){nodes{id state commit{oid}}}
    }
  }
}
]]

---@param pr PullRequest
---@param on_done fun(pull_request_id: string|nil, review: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function find_pending(pr, on_done)
	local owner, name = pr.repo_full_name:match("^([^/]+)/([^/]+)$")
	if owner == nil or name == nil then
		on_done(nil, nil, "Missing repo")
		return nil
	end
	return cli.gh({
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
		if err then
			on_done(nil, nil, err)
			return
		end
		local pull_request = (((result or {}).data or {}).repository or {}).pullRequest
		if type(pull_request) ~= "table" or tostring(pull_request.id or "") == "" then
			on_done(nil, nil, "GitHub did not return the pull request")
			return
		end
		on_done(tostring(pull_request.id), (json.safe_table(pull_request.reviews).nodes or {})[1], nil)
	end, {
		action = "Find pending review",
		repo = pr.repo_full_name,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param review PullsReview|nil
---@param event "COMMENT"|"APPROVE"|"REQUEST_CHANGES"
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function finish(pr, review, event, body, on_done)
	local function done(ok, err)
		if ok then
			M.update(review, nil)
		end
		on_done(ok, err)
	end

	if review and review.pending and review.id then
		return submit_pending(pr, review.id, event, body, done)
	end
	if review and not review.pending then
		local pull_request_id = github_mapping.node_id(pr._raw) or ""
		if pull_request_id == "" then
			done(false, "Missing pull request node id")
			return nil
		end
		return create(pr, pull_request_id, event, body, done)
	end

	local cancelled = false
	local current
	current = find_pending(pr, function(pull_request_id, pending, err)
		if cancelled then
			return
		end
		if err then
			done(false, err)
			return
		end
		M.update(review, pending)
		if pending then
			current = submit_pending(pr, tostring(pending.id), event, body, done)
		else
			current = create(pr, tostring(pull_request_id), event, body, done)
		end
		if cancelled and current then
			current.cancel()
		end
	end)
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
---@param review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.submit(pr, review, body, on_done)
	return finish(pr, review, "COMMENT", body, on_done)
end

---@param pr PullRequest
---@param review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.approve(pr, review, body, on_done)
	return finish(pr, review, "APPROVE", body, on_done)
end

local DISCARD_REVIEW_MUTATION = [[
mutation($reviewId:ID!){
  deletePullRequestReview(input:{pullRequestReviewId:$reviewId}){clientMutationId}
}
]]

---@param pr PullRequest
---@param review PullsReview
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.discard(pr, review, on_done)
	if not review.id then
		on_done(false, "Missing pending review id")
		return nil
	end
	return cli.gh({
		"api",
		"graphql",
		"-f",
		"reviewId=" .. review.id,
		"-f",
		"query=" .. DISCARD_REVIEW_MUTATION,
	}, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		M.update(review, nil)
		on_done(true, nil)
	end, {
		action = "Discard review",
		repo = pr.repo_full_name,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.request_changes(pr, review, body, on_done)
	local message = vim.trim(body) == "" and "Changes requested" or body
	return finish(pr, review, "REQUEST_CHANGES", message, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: { review: PullsReview, comments: PullsComment[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_comments(pr, opts, on_done)
	local owner, name = tostring(pr.repo_full_name or ""):match("^([^/]+)/([^/]+)$")
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
		"number=" .. tostring(pr.id),
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

		pr._raw.node_id = tostring(pull_request.id or "")
		local comments = {}
		for _, thread in ipairs(threads) do
			local nodes = thread.comments and thread.comments.nodes or {}
			for index, node in ipairs(nodes) do
				local root_id = index > 1 and nodes[1] and nodes[1].databaseId or nil
				table.insert(comments, mapper.to_review_comment(node, thread, root_id))
			end
		end
		mapper.normalize_inline_hunks(comments)
		table.sort(comments, function(a, b)
			local left = tostring(a.created_on or "")
			local right = tostring(b.created_on or "")
			return left == right and tostring(a.id) < tostring(b.id) or left < right
		end)
		on_done({
			review = from_node((json.safe_table(pull_request.reviews).nodes or {})[1]),
			comments = comments,
		}, nil)
	end, {
		action = "Fetch comments",
		repo = pr.repo_full_name,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(tasks: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_tasks(pr, opts, on_done)
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
		local tasks = {}
		for _, page in ipairs(result) do
			for _, raw in ipairs(type(page) == "table" and page or {}) do
				vim.list_extend(tasks, mapper.to_tasks(raw))
			end
		end
		table.sort(tasks, function(a, b)
			local left = tostring(a.created_on or "")
			local right = tostring(b.created_on or "")
			return left == right and tostring(a.id) < tostring(b.id) or left < right
		end)
		on_done(tasks, nil)
	end, {
		action = "Fetch checklists",
		repo = pr.repo_full_name,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(data: PullsReviewData|nil, err: string|nil)
---@return { cancel: fun() }
function M.fetch(pr, opts, on_done)
	local remaining = 2
	local review_result, tasks_result
	local review_err
	local function finish_fetch()
		remaining = remaining - 1
		if remaining > 0 then
			return
		end
		if review_err then
			on_done(nil, review_err)
			return
		end
		on_done({
			review = review_result.review,
			comments = review_result.comments,
			tasks = tasks_result,
		}, nil)
	end

	local comments_handle = fetch_comments(pr, opts, function(result, err)
		review_result = result
		review_err = err
		finish_fetch()
	end)
	local tasks_handle = fetch_tasks(pr, opts, function(tasks)
		tasks_result = tasks or {}
		finish_fetch()
	end)

	return {
		cancel = function()
			if comments_handle then
				comments_handle.cancel()
			end
			if tasks_handle then
				tasks_handle.cancel()
			end
		end,
	}
end

---@param pr PullRequest
---@param path string
---@param reviewed boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_file_reviewed(pr, path, reviewed, on_done)
	local pull_request_id = github_mapping.node_id(pr._raw)
	if not pull_request_id then
		on_done(false, "Missing pull request node id")
		return nil
	end
	return cli.gh({
		"api",
		"graphql",
		"-f",
		"query=" .. SET_FILE_REVIEWED_MUTATIONS[reviewed],
		"-f",
		"pullRequestId=" .. pull_request_id,
		"-f",
		"path=" .. path,
	}, function(_, err)
		on_done(err == nil, err)
	end, {
		action = reviewed and "Mark file reviewed" or "Mark file unreviewed",
		repo = pr.repo_full_name,
		number = pr.id,
		path = path,
	})
end

local CREATE_PENDING_REVIEW_MUTATION = [[
mutation($pullRequestId:ID!,$commitOID:GitObjectID){
  addPullRequestReview(input:{pullRequestId:$pullRequestId commitOID:$commitOID}){
    pullRequestReview{id state commit{oid}}
  }
}
]]

---@param pr PullRequest
---@param review PullsReview|nil
---@param commit_oid string
---@param use_review fun(review_id: string): { cancel: fun() }|nil
---@param on_error fun(err: string)
---@return { cancel: fun() }|nil
function M.with_pending(pr, review, commit_oid, use_review, on_error)
	local function use(value)
		if commit_oid ~= "" and value.commit_hash and commit_oid ~= value.commit_hash then
			on_error("Pending review belongs to a different commit")
			return nil
		end
		return use_review(value.id)
	end

	if review and review.pending and review.id then
		return use(review)
	end

	local function create_pending(pull_request_id)
		local args = {
			"api",
			"graphql",
			"-f",
			"pullRequestId=" .. pull_request_id,
			"-f",
			"query=" .. CREATE_PENDING_REVIEW_MUTATION,
		}
		if commit_oid ~= "" then
			vim.list_extend(args, { "-f", "commitOID=" .. commit_oid })
		end

		local cancelled = false
		local current_handle
		current_handle = cli.gh(args, function(result, err)
			if cancelled then
				return
			end
			if err then
				on_error(err)
				return
			end
			local data = result and result.data or {}
			local created = data.addPullRequestReview and data.addPullRequestReview.pullRequestReview
			if type(created) ~= "table" or tostring(created.id or "") == "" then
				on_error("GitHub did not return the pending review")
				return
			end
			M.update(review, created)
			current_handle = use_review(tostring(created.id))
			if cancelled and current_handle then
				current_handle.cancel()
			end
		end, {
			action = "Create pending review",
			repo = pr.repo_full_name,
			number = pr.id,
		})
		return {
			cancel = function()
				cancelled = true
				if current_handle then
					current_handle.cancel()
				end
			end,
		}
	end

	local pull_request_id = github_mapping.node_id(pr._raw) or ""
	if review and not review.pending then
		if pull_request_id == "" then
			on_error("Missing pull request node id")
			return nil
		end
		return create_pending(pull_request_id)
	end

	local cancelled = false
	local current_handle
	current_handle = find_pending(pr, function(found_pr_id, pending, err)
		if cancelled then
			return
		end
		if err then
			on_error(err)
			return
		end
		local found = from_node(pending)
		M.update(review, pending)
		if found.pending and found.id then
			current_handle = use(found)
		else
			current_handle = create_pending(tostring(found_pr_id))
		end
		if cancelled and current_handle then
			current_handle.cancel()
		end
	end)
	return {
		cancel = function()
			cancelled = true
			if current_handle then
				current_handle.cancel()
			end
		end,
	}
end

---@param pr PullRequest
---@param review PullsReview
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.start(pr, review, on_done)
	return M.with_pending(pr, review, tostring(pr.source.commit_hash or ""), function()
		on_done(true, nil)
		return nil
	end, function(err)
		on_done(false, err)
	end)
end

---@param raw table|nil
---@return PullsAuthor|nil
local function review_author(raw)
	if type(raw) ~= "table" or tostring(raw.login or "") == "" then
		return nil
	end
	local login = tostring(raw.login)
	return {
		id = tostring(raw.id or login),
		name = tostring(raw.name or login),
		username = login,
		nickname = login,
	}
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(context: PullsReviewContext|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_context(pr, opts, on_done)
	local repo_slug = pr.repo_full_name or ""
	local owner, repo = repo_slug:match("^([^/]+)/(.+)$")
	if not owner or not repo then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local cache_key = string.format("github:review-context:%s:%s", repo_slug, tostring(pr.id))
	opts = opts or {}
	if not opts.force_refresh then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"api",
		"graphql",
		"--paginate",
		"--slurp",
		"-f",
		"query=" .. REVIEW_CONTEXT_QUERY,
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. repo,
		"-F",
		"number=" .. tostring(pr.id),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch review context")
			return
		end
		local pull_request
		local reviewed_files = {}
		for _, page in ipairs(result) do
			local current = (((page or {}).data or {}).repository or {}).pullRequest
			if type(current) ~= "table" then
				on_done(nil, "Failed to fetch review context")
				return
			end
			pull_request = pull_request or current
			for _, file in ipairs(((current.files or {}).nodes or {})) do
				if file.viewerViewedState == "VIEWED" then
					reviewed_files[tostring(file.path)] = true
				end
			end
		end
		if not pull_request then
			on_done(nil, "Failed to fetch review context")
			return
		end
		pr._raw.node_id = tostring(pull_request.id or "")

		local authors = {}
		local seen = {}
		local function add(author)
			if author == nil then
				return
			end
			local key = tostring(author.username or author.nickname or author.name or ""):lower()
			if key ~= "" and not seen[key] then
				seen[key] = true
				table.insert(authors, author)
			end
		end

		add(pr.author)
		for _, raw in ipairs(((pull_request.assignees or {}).nodes or {})) do
			add(review_author(raw))
		end
		for _, raw in ipairs(((pull_request.reviews or {}).nodes or {})) do
			add(review_author(type(raw) == "table" and raw.author or nil))
		end
		for _, raw in ipairs(((pull_request.reviewRequests or {}).nodes or {})) do
			add(review_author(type(raw) == "table" and (raw.requestedReviewer or raw) or nil))
		end

		local context = { authors = authors, reviewed_files = reviewed_files }
		cli.set_mem(cache_key, context, cli.cache_ttl())
		on_done(context, nil)
	end, {
		action = "Fetch PR review context",
		repo = repo_slug,
		number = pr.id,
	})
end

return M
