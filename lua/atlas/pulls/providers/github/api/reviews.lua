local M = {}

local cli = require("atlas.providers.github.client")
local json = require("atlas.core.json")
local mapper = require("atlas.pulls.providers.github.api.mapper")
local github_mapping = require("atlas.providers.github.mapping")
local request_scope = require("atlas.core.requests")

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
          resolvedBy{login databaseId}
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
      reviewRequests(first:100){
        nodes{
          requestedReviewer{
            ... on User{id login name}
            ... on Bot{id login}
            ... on Mannequin{id login name}
            ... on Team{id name slug organization{login}}
            ... on EnterpriseTeam{id name slug combinedSlug}
          }
        }
      }
      files(first:100,after:$endCursor){
        pageInfo{hasNextPage endCursor}
        nodes{path viewerViewedState}
      }
    }
  }
}
]]

local REVIEWERS_QUERY = [[
query($owner:String!,$name:String!,$number:Int!,$endCursor:String){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      reviews(first:100,after:$endCursor){
        pageInfo{hasNextPage endCursor}
        nodes{
          state
          author{login ... on User{id name} ... on Bot{id}}
        }
      }
      reviewRequests(first:100){
        nodes{
          requestedReviewer{
            ... on User{id login name}
            ... on Bot{id login}
            ... on Mannequin{id login name}
            ... on Team{id name slug organization{login}}
            ... on EnterpriseTeam{id name slug combinedSlug}
          }
        }
      }
      reviewRequestEvents:timelineItems(last:100,itemTypes:[REVIEW_REQUESTED_EVENT]){
        nodes{
          ... on ReviewRequestedEvent{
            requestedReviewer{
              ... on User{id login name}
              ... on Bot{id login}
              ... on Mannequin{id login name}
              ... on Team{id name slug organization{login}}
              ... on EnterpriseTeam{id name slug combinedSlug}
            }
          }
        }
      }
    }
  }
}
]]

local REVIEW_DETAILS_QUERY = [[
query($owner:String!,$name:String!,$number:Int!,$endCursor:String){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      reviews(first:100,after:$endCursor){
        pageInfo{hasNextPage endCursor}
        nodes{
          id
          state
          submittedAt
          updatedAt
          body
          url
          commit{oid}
          author{login ... on User{id name} ... on Bot{id}}
        }
      }
      reviewRequests(first:100){
        nodes{
          requestedReviewer{
            ... on User{id login name}
            ... on Bot{id login}
            ... on Mannequin{id login name}
            ... on Team{id name slug organization{login}}
            ... on EnterpriseTeam{id name slug combinedSlug}
          }
        }
      }
      reviewRequestEvents:timelineItems(last:100,itemTypes:[REVIEW_REQUESTED_EVENT]){
        nodes{
          ... on ReviewRequestedEvent{
            requestedReviewer{
              ... on User{id login name}
              ... on Bot{id login}
              ... on Mannequin{id login name}
              ... on Team{id name slug organization{login}}
              ... on EnterpriseTeam{id name slug combinedSlug}
            }
          }
        }
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
	local id = node and tostring(node.id or "") or ""
	local commit_hash = node and tostring((node.commit or {}).oid or "") or ""
	return {
		id = id ~= "" and id or nil,
		commit_hash = commit_hash ~= "" and commit_hash or nil,
		pending = node ~= nil and node.state == "PENDING",
	}
end

---@param raw table|nil
---@return PullsAuthor|nil
local function review_author(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local user = github_mapping.identity(raw) or { id = "", login = "", name = "" }
	local slug = json.safe_str(raw.slug) or ""
	local organization = json.safe_table(raw.organization)
	local organization_login = json.safe_str(organization.login) or ""
	local team = json.safe_str(raw.combinedSlug)
		or (organization_login ~= "" and slug ~= "" and organization_login .. "/" .. slug or slug)
	local login = user.login ~= "" and user.login or team
	if not login or login == "" then
		return nil
	end
	return {
		id = user.id ~= "" and user.id or login,
		name = user.name ~= "" and user.name or (json.safe_str(raw.name) or login),
		username = login,
		nickname = login,
	}
end

---@param pr PullRequest
---@return string
local function review_details_cache_key(pr)
	return string.format("github:review-details:%s:%s", pr.repo_full_name, tostring(pr.id))
end

---@param pr PullRequest
---@return string
local function reviewers_cache_key(pr)
	return string.format("github:reviewers:%s:%s", pr.repo_full_name, tostring(pr.id))
end

---@param pr PullRequest
local function clear_review_caches(pr)
	cli.delete_mem(review_details_cache_key(pr))
	cli.delete_mem(reviewers_cache_key(pr))
	cli.delete_mem(string.format("github:merge-checks:%s:%s", pr.repo_full_name, tostring(pr.id)))
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
		if err or type(result) ~= "table" then
			on_done(false, err or "Failed to submit review")
			return
		end
		local payload = json.nilify(result.data.submitPullRequestReview)
		local review = payload and json.nilify(payload.pullRequestReview)
		if not review or tostring(review.id or "") == "" then
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
		if err or type(result) ~= "table" then
			on_done(false, err or "Failed to submit review")
			return
		end
		local payload = json.nilify(result.data.addPullRequestReview)
		local review = payload and json.nilify(payload.pullRequestReview)
		if not review or tostring(review.id or "") == "" then
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
	local owner, name = pr.workspace, pr.repo
	if owner == "" or name == "" then
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
		if err or type(result) ~= "table" then
			on_done(nil, nil, err or "Failed to find pending review")
			return
		end
		local repository = json.nilify(result.data.repository)
		local pull_request = repository and json.nilify(repository.pullRequest)
		if not pull_request or tostring(pull_request.id or "") == "" then
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
	---@cast pr GitHubPullRequest
	local function done(ok, err)
		if ok then
			M.update(review, nil)
			clear_review_caches(pr)
		end
		on_done(ok, err)
	end

	if review and review.pending and review.id then
		return submit_pending(pr, review.id, event, body, done)
	end
	if review and not review.pending then
		local pull_request_id = pr.node_id or ""
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
		clear_review_caches(pr)
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
	return finish(pr, review, "REQUEST_CHANGES", body, on_done)
end

local HISTORY_STATES = {
	APPROVED = "approved",
	CHANGES_REQUESTED = "changes_requested",
	COMMENTED = "commented",
	DISMISSED = "dismissed",
}

local UPDATE_REVIEW_MUTATION = [[
mutation($reviewId:ID!,$body:String!){
  updatePullRequestReview(input:{pullRequestReviewId:$reviewId,body:$body}){
    clientMutationId
  }
}
]]

---@param pr PullRequest
---@param review_id string
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_review(pr, review_id, body, on_done)
	if review_id == "" then
		vim.schedule(function()
			on_done(false, "Missing review id")
		end)
		return nil
	end

	return cli.gh({
		"api",
		"graphql",
		"-f",
		"reviewId=" .. review_id,
		"-f",
		"body=" .. body,
		"-f",
		"query=" .. UPDATE_REVIEW_MUTATION,
	}, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		clear_review_caches(pr)
		on_done(true, nil)
	end, {
		action = "Edit review",
		repo = pr.repo_full_name,
		number = pr.id,
		review_id = review_id,
	})
end

---@param pages table[]
---@return { reviewers: PullsReviewer[], history: PullsReviewHistoryEntry[] }|nil
local function review_details(pages)
	local pull_request
	local history = {}
	local review_nodes = {}
	for _, page in ipairs(pages) do
		local data = json.nilify(page.data)
		local repository = data and json.nilify(data.repository)
		local current = repository and json.nilify(repository.pullRequest)
		if not current then
			return nil
		end
		pull_request = pull_request or current
		for _, node in ipairs(((current.reviews or {}).nodes or {})) do
			table.insert(review_nodes, node)
			local state = HISTORY_STATES[tostring(node.state or "")]
			local body = json.safe_str(node.body) or ""
			if vim.trim(body) == "" then
				body = nil
			end
			if state then
				local id = json.safe_str(node.id)
				local commit_hash = json.safe_str(json.safe_table(node.commit).oid)
				local url = json.safe_str(node.url)
				local submitted_on = state == "dismissed" and json.safe_str(node.updatedAt)
					or json.safe_str(node.submittedAt)
				table.insert(history, {
					id = id,
					author = review_author(node.author),
					state = state,
					submitted_on = submitted_on or "",
					body = body,
					commit_hash = commit_hash,
					url = url,
				})
			end
		end
	end
	if not pull_request then
		return nil
	end
	table.sort(history, function(left, right)
		if left.submitted_on ~= right.submitted_on then
			return left.submitted_on < right.submitted_on
		end
		return tostring(left.id or "") < tostring(right.id or "")
	end)
	-- Keep the latest empty dismissal per author the older ones only add noise.
	local latest = {}
	for index, entry in ipairs(history) do
		if entry.author then
			latest[entry.author.id] = index
		end
	end
	local visible = {}
	for index, entry in ipairs(history) do
		local latest_for_author = entry.author and latest[entry.author.id] == index
		local empty_commented = entry.state == "commented" and not entry.body
		local old_empty_dismissal = entry.state == "dismissed" and not entry.body and not latest_for_author
		if not empty_commented and not old_empty_dismissal then
			table.insert(visible, entry)
		end
	end
	return {
		reviewers = mapper.to_reviewers({
			reviews = { nodes = review_nodes },
			reviewRequests = pull_request.reviewRequests,
			reviewRequestEvents = pull_request.reviewRequestEvents,
		}) or {},
		history = visible,
	}
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: { reviewers: PullsReviewer[], history: PullsReviewHistoryEntry[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_review_details(pr, opts, on_done)
	local owner, name = pr.workspace, pr.repo
	if owner == "" or name == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = review_details_cache_key(pr)
	if not (opts or {}).force_refresh then
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
		"-F",
		"owner=" .. owner,
		"-F",
		"name=" .. name,
		"-F",
		"number=" .. tostring(pr.id),
		"-f",
		"query=" .. REVIEW_DETAILS_QUERY,
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch review history")
			return
		end
		local details = review_details(result)
		if not details then
			on_done(nil, "Missing pull request review history")
			return
		end
		cli.set_mem(cache_key, details, cli.cache_ttl())
		on_done(details, nil)
	end, {
		action = "Fetch PR review history",
		repo = pr.repo_full_name,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewers(pr, opts, on_done)
	local owner, name = pr.workspace, pr.repo
	if owner == "" or name == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = reviewers_cache_key(pr)
	if not (opts or {}).force_refresh then
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
		"-F",
		"owner=" .. owner,
		"-F",
		"name=" .. name,
		"-F",
		"number=" .. tostring(pr.id),
		"-f",
		"query=" .. REVIEWERS_QUERY,
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch reviewers")
			return
		end

		local pull_request
		local review_nodes = {}
		for _, page in ipairs(result) do
			local data = json.nilify(page.data)
			local repository = data and json.nilify(data.repository)
			local current = repository and json.nilify(repository.pullRequest)
			if not current then
				on_done(nil, "Missing pull request reviewers")
				return
			end
			pull_request = pull_request or current
			vim.list_extend(review_nodes, ((current.reviews or {}).nodes or {}))
		end
		if not pull_request then
			on_done(nil, "Missing pull request reviewers")
			return
		end

		local reviewers = mapper.to_reviewers({
			reviews = { nodes = review_nodes },
			reviewRequests = pull_request.reviewRequests,
			reviewRequestEvents = pull_request.reviewRequestEvents,
		}) or {}
		cli.set_mem(cache_key, reviewers, cli.cache_ttl())
		on_done(reviewers, nil)
	end, {
		action = "Fetch PR reviewers",
		repo = pr.repo_full_name,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: { review: PullsReview, comments: PullsComment[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_comments(pr, _opts, on_done)
	---@cast pr GitHubPullRequest
	local owner, name = pr.workspace, pr.repo
	if owner == "" or name == "" then
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
			local repository = json.nilify(page.data.repository)
			local page_pr = repository and json.nilify(repository.pullRequest)
			if not page_pr then
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

		pr.node_id = tostring(pull_request.id or "")
		local comments = {}
		for _, thread in ipairs(threads) do
			local nodes = thread.comments and thread.comments.nodes or {}
			for index, node in ipairs(nodes) do
				local root_id = index > 1 and nodes[1] and nodes[1].databaseId or nil
				table.insert(comments, mapper.to_review_comment(node, thread, root_id))
			end
		end
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
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(tasks: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_tasks(pr, _opts, on_done)
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
			for _, raw in ipairs(page) do
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
	local requests = request_scope.new()
	requests.all({
		comments = function(done)
			return fetch_comments(pr, opts, done)
		end,
		tasks = function(done)
			return fetch_tasks(pr, opts, done)
		end,
		details = function(done)
			return fetch_review_details(pr, opts, done)
		end,
	}, function(results, errors)
		if errors.comments or errors.details then
			on_done(nil, errors.comments or errors.details)
			return
		end
		on_done({
			review = results.comments.review,
			comments = results.comments.comments,
			tasks = results.tasks or {},
			reviewers = results.details.reviewers,
			history = results.details.history,
		}, nil)
	end)
	return requests
end

---@param pr PullRequest
---@param path string
---@param reviewed boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_file_reviewed(pr, path, reviewed, on_done)
	---@cast pr GitHubPullRequest
	local pull_request_id = pr.node_id
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
		if err == nil then
			cli.delete_mem(string.format("github:review-context:%s:%s", pr.repo_full_name, tostring(pr.id)))
		end
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
	---@cast pr GitHubPullRequest
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
			if err or type(result) ~= "table" then
				on_error(err or "Failed to create pending review")
				return
			end
			local data = result.data
			local created = json.nilify(data.addPullRequestReview and data.addPullRequestReview.pullRequestReview)
			if not created or tostring(created.id or "") == "" then
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

	local pull_request_id = pr.node_id or ""
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
	return M.with_pending(pr, review, pr.source.commit_hash, function()
		on_done(true, nil)
		return nil
	end, function(err)
		on_done(false, err)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(context: PullsReviewContext|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_context(pr, opts, on_done)
	---@cast pr GitHubPullRequest
	local repo_slug = pr.repo_full_name
	local owner, repo = pr.workspace, pr.repo
	if owner == "" or repo == "" then
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
			local repository = json.nilify(page.data.repository)
			local current = repository and json.nilify(repository.pullRequest)
			if not current then
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
		pr.node_id = tostring(pull_request.id or "")

		local mention_candidates = {}
		local seen = {}
		local function add(author)
			if author == nil then
				return
			end
			local key = tostring(author.username or author.nickname or author.name or ""):lower()
			if key ~= "" and not seen[key] then
				seen[key] = true
				table.insert(mention_candidates, author)
			end
		end

		add(pr.author)
		for _, raw in ipairs(((pull_request.assignees or {}).nodes or {})) do
			add(review_author(raw))
		end
		for _, raw in ipairs(((pull_request.reviews or {}).nodes or {})) do
			add(review_author(raw.author))
		end
		for _, raw in ipairs(((pull_request.reviewRequests or {}).nodes or {})) do
			add(review_author(raw.requestedReviewer or raw))
		end

		local context = { mention_candidates = mention_candidates, reviewed_files = reviewed_files }
		cli.set_mem(cache_key, context, cli.cache_ttl())
		on_done(context, nil)
	end, {
		action = "Fetch PR review context",
		repo = repo_slug,
		number = pr.id,
	})
end

return M
