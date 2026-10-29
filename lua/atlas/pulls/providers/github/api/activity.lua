local M = {}

local cli = require("atlas.providers.github.client")
local json = require("atlas.core.json")
local mapper = require("atlas.pulls.providers.github.api.mapper")

local TIMELINE_QUERY = [[
query($owner:String!,$name:String!,$number:Int!,$endCursor:String){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      id url body createdAt authorAssociation author{...actor}
      reactionGroups{content viewerHasReacted reactors(first:10){totalCount nodes{...on User{login name} ...on Bot{login}}}}
      timelineItems(first:100,after:$endCursor){
        pageInfo{hasNextPage endCursor}
        nodes{
          __typename
          ...on IssueComment{
            id url body createdAt authorAssociation author{...actor}
            reactionGroups{content viewerHasReacted reactors(first:10){totalCount nodes{...on User{login name} ...on Bot{login}}}}
          }
          ...on PullRequestReview{id state body submittedAt url commit{oid} author{...actor}}
          ...on PullRequestCommit{commit{oid message authoredDate author{name user{login}}}}
          ...on ReviewDismissedEvent{createdAt actor{...actor} previousReviewState review{id}}
          ...on ReviewRequestedEvent{createdAt actor{...actor} requestedReviewer{...actor}}
          ...on HeadRefForcePushedEvent{createdAt actor{...actor}}
          ...on BaseRefForcePushedEvent{createdAt actor{...actor}}
          ...on MergedEvent{createdAt actor{...actor}}
          ...on ClosedEvent{createdAt actor{...actor}}
          ...on ReopenedEvent{createdAt actor{...actor}}
          ...on LabeledEvent{createdAt actor{...actor} label{name}}
          ...on UnlabeledEvent{createdAt actor{...actor} label{name}}
          ...on AssignedEvent{createdAt actor{...actor} assignee{...actor}}
          ...on UnassignedEvent{createdAt actor{...actor} assignee{...actor}}
          ...on RenamedTitleEvent{createdAt actor{...actor} previousTitle currentTitle}
          ...on CommentDeletedEvent{createdAt actor{...actor}}
          ...on ReadyForReviewEvent{createdAt actor{...actor}}
          ...on ConvertToDraftEvent{createdAt actor{...actor}}
        }
      }
    }
  }
}
fragment actor on Actor{__typename login ...on User{databaseId} ...on Bot{databaseId}}
]]

---@param entries PullsActivityEntry[]
---@return PullsActivityEntry[]
local function squash_commits(entries)
	local squashed = {}
	local run_start, run_count = nil, 0
	local function flush()
		if run_start ~= nil then
			run_start.label = string.format("added %d commit%s", run_count, run_count == 1 and "" or "s")
			run_start.kind = "update"
			table.insert(squashed, run_start)
			run_start, run_count = nil, 0
		end
	end
	for _, entry in ipairs(entries) do
		if entry.kind == "committed" then
			if run_start == nil then
				run_start = entry
				run_count = 1
			else
				run_count = run_count + 1
				run_start.date = entry.date or run_start.date
			end
		else
			flush()
			table.insert(squashed, entry)
		end
	end
	flush()
	return squashed
end

---@param pr PullRequest
---@param on_done fun(pulls: table[]|nil, err: string|nil) One GraphQL `PullRequest` per page
---@return { cancel: fun() }|nil
local function fetch_timeline(pr, on_done)
	local owner, name = (pr.repo_full_name or ""):match("^([^/]+)/(.+)$")
	if not owner then
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
		"-f",
		"owner=" .. owner,
		"-f",
		"name=" .. name,
		"-F",
		"number=" .. tostring(pr.id),
		"-f",
		"query=" .. TIMELINE_QUERY,
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch pull request timeline")
			return
		end
		local pulls = {}
		for _, page in ipairs(result) do
			table.insert(pulls, json.safe_table(json.safe_table(json.safe_table(page.data).repository).pullRequest))
		end
		on_done(pulls, nil)
	end, {
		action = "Fetch pull request timeline",
		repo = pr.repo_full_name,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(conversation: PullsConversation|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(pr, _opts, on_done)
	return fetch_timeline(pr, function(pulls, err)
		if not pulls then
			on_done(nil, err)
			return
		end

		local nodes = {}
		for _, pull in ipairs(pulls) do
			vim.list_extend(nodes, json.safe_table(json.safe_table(pull.timelineItems).nodes))
		end

		local dismissed_states = {}
		for _, node in ipairs(nodes) do
			local review_id = node.__typename == "ReviewDismissedEvent" and json.safe_table(node.review).id
			if review_id then
				dismissed_states[review_id] = (json.safe_str(node.previousReviewState) or ""):lower()
			end
		end

		local comments, reviews, events = {}, {}, {}
		for _, node in ipairs(nodes) do
			if node.__typename == "IssueComment" then
				table.insert(comments, mapper.to_comment(node, pr.author.username))
			else
				local review = node.__typename == "PullRequestReview" and mapper.to_conversation_review(node) or nil
				if review then
					review.previous_state = dismissed_states[review.id]
					table.insert(reviews, review)
				else
					local entry = mapper.to_activity(node)
					if entry then
						table.insert(events, entry)
					end
				end
			end
		end

		on_done({
			description = pulls[1] and mapper.to_description(pulls[1], pr.author.username),
			comments = comments,
			reviews = reviews,
			activities = squash_commits(events),
		}, nil)
	end)
end

return M
