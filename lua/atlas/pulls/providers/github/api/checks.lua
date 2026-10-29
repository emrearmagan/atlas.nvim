local cli = require("atlas.providers.github.client")
local icons = require("atlas.ui.shared.icons")
local json = require("atlas.core.json")

local M = {}

local STACK_FIELDS = [[
      stackEntry {
        position
        stack {
          number
          baseRefName
          entries(first: 50) {
            nodes {
              position
              pullRequest { number title state isDraft mergeable mergeStateStatus }
            }
          }
        }
      }
]]

local MERGE_CHECKS_QUERY = [[
query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      mergeable
      reviewDecision
      reviewRequests(first: 100) {
        nodes { requestedReviewer { ... on User { login } ... on Bot { login } } }
      }
      reviews(first: 100, after: $endCursor) {
        nodes { author { login } state submittedAt }
        pageInfo { hasNextPage endCursor }
      }
      commits(last: 1) {
        nodes { commit { statusCheckRollup { state } } }
      }
%s
    }
  }
}
]]

---@return string
local function merge_checks_query()
	if cli.is_enterprise_server() then
		return string.format(MERGE_CHECKS_QUERY, "")
	end
	return string.format(MERGE_CHECKS_QUERY, STACK_FIELDS)
end

---@type table<string, "successful"|"failed"|"inprogress">
local PIPELINE_STATES = {
	ERROR = "failed",
	EXPECTED = "inprogress",
	FAILURE = "failed",
	PENDING = "inprogress",
	SUCCESS = "successful",
}

---@class GitHubMergeStack
---@field number integer
---@field base string|nil
---@field position integer
---@field entries { position: integer, number: integer|nil, title: string, state: "open"|"merged"|"closed"|"draft", conflicting: boolean, merge_state: string }[]

---@class GitHubMergeState
---@field mergeable string
---@field review_decision string
---@field review_requests string[]
---@field latest_reviews { login: string, state: string }[]
---@field pipeline_state "successful"|"failed"|"inprogress"|nil
---@field stack GitHubMergeStack|nil

---@return { login: string, state: "APPROVED"|"CHANGES_REQUESTED"|"DISMISSED" }[], string[]
local function parse_reviews(review_nodes, request_nodes)
	local latest = {}
	local order = {}
	for _, review in ipairs(review_nodes) do
		local author = json.nilify(review.author)
		local login = author and tostring(author.login or "") or ""
		local state = tostring(review.state or ""):upper()
		if login ~= "" and state ~= "PENDING" and state ~= "COMMENTED" then
			local at = tostring(review.submittedAt or "")
			local prev = latest[login]
			if prev == nil then
				table.insert(order, login)
				latest[login] = { state = state, at = at }
			elseif at >= prev.at then
				latest[login] = { state = state, at = at }
			end
		end
	end

	local reviews = {}
	for _, login in ipairs(order) do
		table.insert(reviews, { login = login, state = latest[login].state })
	end

	local pending = {}
	for _, req in ipairs(request_nodes) do
		local reviewer = json.safe_table(req.requestedReviewer)
		local login = tostring(reviewer.login or "")
		if login ~= "" and latest[login] == nil then
			table.insert(pending, login)
		end
	end

	return reviews, pending
end

---@param raw any
---@return GitHubMergeStack|nil
local function parse_stack(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local stack = json.safe_table(raw.stack)
	local number = tonumber(stack.number)
	local position = tonumber(raw.position)
	if number == nil or position == nil then
		return nil
	end

	local entries = {}
	for _, node in ipairs(json.safe_table(json.safe_table(stack.entries).nodes)) do
		local entry = json.safe_table(node)
		local pr = json.safe_table(entry.pullRequest)
		local pr_state = tostring(pr.state or ""):upper()
		local state = "open"
		if pr_state == "MERGED" then
			state = "merged"
		elseif pr_state == "CLOSED" then
			state = "closed"
		elseif pr.isDraft == true then
			state = "draft"
		end
		table.insert(entries, {
			position = tonumber(entry.position) or 0,
			number = tonumber(pr.number),
			title = json.safe_str(pr.title) or "",
			state = state,
			conflicting = pr.mergeable == "CONFLICTING",
			merge_state = tostring(pr.mergeStateStatus or ""),
		})
	end
	if #entries < 2 then
		return nil
	end
	table.sort(entries, function(a, b)
		return a.position < b.position
	end)

	return {
		number = number,
		base = json.safe_str(stack.baseRefName),
		position = position,
		entries = entries,
	}
end

---@param pr PullRequest
---@param on_done fun(result: GitHubMergeState|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_merge_state(pr, on_done)
	local repo_slug = pr.repo_full_name
	local owner, repo = repo_slug:match("^([^/]+)/([^/]+)$")
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
		"query=" .. merge_checks_query(),
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. repo,
		"-F",
		"number=" .. tostring(pr.id),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch merge checks")
			return
		end

		local pull_request
		local review_nodes = {}
		for _, page in ipairs(result) do
			local repository = json.safe_table(json.safe_table(page.data).repository)
			local current = json.nilify(repository.pullRequest)
			if not current then
				on_done(nil, "Pull request not found")
				return
			end
			pull_request = pull_request or current
			vim.list_extend(review_nodes, current.reviews.nodes)
		end
		if not pull_request then
			on_done(nil, "Pull request not found")
			return
		end

		local latest_reviews, review_requests = parse_reviews(review_nodes, pull_request.reviewRequests.nodes)
		local last_commit = pull_request.commits.nodes[1]
		local rollup = last_commit and json.nilify(last_commit.commit.statusCheckRollup)
		local out = {
			mergeable = pull_request.mergeable,
			review_decision = json.safe_str(pull_request.reviewDecision) or "",
			review_requests = review_requests,
			latest_reviews = latest_reviews,
			pipeline_state = rollup and PIPELINE_STATES[rollup.state] or nil,
			stack = parse_stack(pull_request.stackEntry),
		}
		on_done(out, nil)
	end, {
		action = "Fetch PR merge state",
		repo = repo_slug,
		number = pr.id,
	})
end

---@param mc GitHubMergeState
---@return PullsMergeCheck
local function reviews_check(mc)
	local rd = tostring(mc.review_decision or "")
	local requests = mc.review_requests
	local reviews = mc.latest_reviews

	local approved, changes_requested = 0, 0
	for _, r in ipairs(reviews) do
		if r.state == "APPROVED" then
			approved = approved + 1
		elseif r.state == "CHANGES_REQUESTED" then
			changes_requested = changes_requested + 1
		end
	end

	if rd == "" and approved == 0 and changes_requested == 0 and #requests == 0 then
		return { key = "reviews", state = "muted", label = "Reviews", details = { "No review required" } }
	end

	local details = {}
	if approved > 0 then
		table.insert(details, string.format("%d %s", approved, approved == 1 and "approval" or "approvals"))
	end
	if changes_requested > 0 then
		table.insert(
			details,
			string.format(
				"%d %s requested changes",
				changes_requested,
				changes_requested == 1 and "reviewer" or "reviewers"
			)
		)
	end
	if #requests > 0 then
		table.insert(details, string.format("%d pending %s", #requests, #requests == 1 and "review" or "reviews"))
	elseif rd == "REVIEW_REQUIRED" then
		table.insert(details, "Review required")
	end

	local state
	if rd == "CHANGES_REQUESTED" or changes_requested > 0 then
		state = "failed"
	elseif #requests > 0 or rd == "REVIEW_REQUIRED" then
		state = "warning"
	elseif rd == "APPROVED" or approved > 0 then
		state = "successful"
	else
		state = "muted"
	end

	return { key = "reviews", state = state, label = "Reviews", details = details }
end

---@param mergeable string
---@return PullsMergeCheck|nil
local function conflicts_check(mergeable)
	local m = tostring(mergeable or "")
	if m == "MERGEABLE" then
		return {
			key = "conflicts",
			state = "successful",
			label = "No conflicts with base branch",
			details = { "Changes can be cleanly merged" },
		}
	elseif m == "CONFLICTING" then
		return {
			key = "conflicts",
			state = "failed",
			label = "This branch has conflicts that must be resolved",
			details = { "Conflicting files must be resolved before merging" },
		}
	end
	return nil
end

---@param stack GitHubMergeStack|nil
---@return PullsMergeCheck|nil
local function stack_check(stack)
	if stack == nil then
		return nil
	end

	---@type PullsMergeCheckDetail[]
	local details = {}
	if stack.base then
		local icon, icon_hl = icons.get("pending")
		table.insert(details, { text = stack.base, icon = icon, icon_hl = icon_hl })
	end

	local state = "successful"
	local blocked_below = false
	for _, entry in ipairs(stack.entries) do
		local merge_state = entry.merge_state

		local icon_name = "success"
		local entry_state = "successful"
		if entry.state == "merged" then
			icon_name = "merged_pr"
		elseif entry.state == "closed" then
			icon_name = "declined_pr"
			entry_state = "failed"
		elseif entry.state == "draft" then
			icon_name = "draft_pr"
			entry_state = "warning"
		elseif entry.conflicting then
			icon_name = "error"
			entry_state = "failed"
		elseif blocked_below or merge_state == "BLOCKED" or merge_state == "BEHIND" or merge_state == "UNSTABLE" then
			icon_name = "progress"
			entry_state = "warning"
		end
		if entry_state ~= "successful" then
			blocked_below = true
		end
		local icon, icon_hl = icons.get(icon_name)

		local text_hl = nil
		if entry.position == stack.position then
			text_hl = "Normal"
			state = entry_state
		end

		local text = string.format("#%s %s", entry.number or "-", entry.title)
		table.insert(details, 1, { text = text, text_hl = text_hl, icon = icon, icon_hl = icon_hl })
	end

	return { key = "stack", state = state, label = "Stack #" .. stack.number, details = details }
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(checks: PullsMergeCheck[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
	local cache_key = string.format("github:merge-checks:%s:%s", pr.repo_full_name, tostring(pr.id))
	if not (opts or {}).force_refresh then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return fetch_merge_state(pr, function(mc_result, err)
		if not mc_result then
			on_done(nil, err or "Failed to load merge checks")
			return
		end
		local checks = {}
		if pr.state == "draft" then
			table.insert(checks, {
				key = "draft",
				state = "warning",
				label = "This pull request is still a work in progress",
				details = { "Draft pull requests cannot be merged" },
			})
		end
		table.insert(checks, reviews_check(mc_result))

		if mc_result.pipeline_state then
			table.insert(checks, {
				key = "pipelines",
				label = "Pipelines",
				state = mc_result.pipeline_state,
			})
		end

		local c = conflicts_check(mc_result.mergeable)
		if c then
			table.insert(checks, c)
		end

		local stack = stack_check(mc_result.stack)
		if stack then
			table.insert(checks, stack)
		end

		cli.set_mem(cache_key, checks, cli.cache_ttl())
		on_done(checks, nil)
	end)
end

return M
