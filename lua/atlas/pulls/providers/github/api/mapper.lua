local M = {}

local json = require("atlas.core.json")
local github_mapper = require("atlas.providers.github.mapper")

---@param value any
---@return string
local function body_text(value)
	return json.safe_str(value) or ""
end

---@param login string
---@return AtlasUser|nil
local function actor_from_login(login)
	if login == "" then
		return nil
	end
	return { name = login, id = "", username = login }
end

---@param raw any
---@return AtlasUser
local function pull_author(raw)
	local user = github_mapper.identity(raw) or { id = "", login = "", name = "" }
	return { name = user.name, id = user.id, username = user.login }
end

---@param raw any
---@return AtlasUser
local function comment_author(raw)
	local user = github_mapper.identity(raw) or { id = "", login = "" }
	return { name = user.login, id = user.id, username = user.login }
end

---@param raw table
---@return AtlasUser[]|nil
local function pull_assignees(raw)
	if json.nilify(raw.assignees) == nil then
		return nil
	end

	local assignees = {}
	for _, node in ipairs(github_mapper.connection_nodes(raw.assignees)) do
		local assignee = pull_author(node)
		if assignee.username ~= "" then
			table.insert(assignees, assignee)
		end
	end
	return assignees
end

---@param raw table
---@return PullsLabel[]|nil
local function pull_labels(raw)
	if json.nilify(raw.labels) == nil then
		return nil
	end

	local labels = {}
	for _, node in ipairs(github_mapper.connection_nodes(raw.labels)) do
		local name = json.safe_str(node.name)
		if name and name ~= "" then
			table.insert(labels, { name = name, color = json.safe_str(node.color) })
		end
	end
	return labels
end

---@param left PullsReviewer
---@param right PullsReviewer
---@return boolean
local function same_reviewer(left, right)
	return left.provider_id:lower() == right.provider_id:lower()
end

---@param reviewers PullsReviewer[]
---@param reviewer PullsReviewer
local function upsert_reviewer(reviewers, reviewer)
	for index, existing in ipairs(reviewers) do
		if same_reviewer(existing, reviewer) then
			reviewers[index] = reviewer
			return
		end
	end
	table.insert(reviewers, reviewer)
end

---@param reviewers PullsReviewer[]
---@param reviewer PullsReviewer
local function remove_reviewer(reviewers, reviewer)
	for index, existing in ipairs(reviewers) do
		if same_reviewer(existing, reviewer) then
			table.remove(reviewers, index)
			return
		end
	end
end

---@param raw any
---@param decision "approved"|"changes_requested"|"pending"
---@param role "reviewer"|"participant"
---@return PullsReviewer|nil
local function pull_reviewer(raw, decision, role)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local user = github_mapper.identity(raw) or { id = "", login = "", name = "" }
	local slug = json.safe_str(raw.slug) or ""
	local combined_slug = json.safe_str(raw.combinedSlug) or ""
	local organization_login = json.safe_str(json.safe_table(raw.organization).login) or ""
	local team = combined_slug ~= "" and combined_slug
		or (organization_login ~= "" and slug ~= "" and organization_login .. "/" .. slug or slug)
	local username = user.login ~= "" and user.login or team
	if username == "" then
		return nil
	end
	local name = user.name ~= "" and user.name or (json.safe_str(raw.teamName) or username)

	return {
		id = user.id ~= "" and user.id or username,
		provider_id = username,
		name = name,
		username = username,
		decision = decision,
		role = role,
	}
end

---@param raw table
---@return PullsReviewer[]|nil
function M.to_reviewers(raw)
	local has_reviews = json.nilify(raw.reviews) ~= nil
	local has_requests = json.nilify(raw.reviewRequests) ~= nil
	local reviewers = (has_reviews or has_requests) and {} or nil
	if reviewers == nil then
		return nil
	end

	local requested = {}
	for _, node in ipairs(github_mapper.connection_nodes(raw.reviewRequestEvents)) do
		local reviewer = pull_reviewer(node.requestedReviewer, "pending", "reviewer")
		if reviewer then
			requested[reviewer.provider_id:lower()] = true
		end
	end

	local active = {}
	for _, node in ipairs(github_mapper.connection_nodes(raw.reviewRequests)) do
		local reviewer = pull_reviewer(node.requestedReviewer or node, "pending", "reviewer")
		if reviewer then
			requested[reviewer.provider_id:lower()] = true
			table.insert(active, reviewer)
		end
	end

	for _, node in ipairs(github_mapper.connection_nodes(raw.reviews)) do
		local state = tostring(node.state or ""):upper()
		local decision = state == "APPROVED" and "approved"
			or state == "CHANGES_REQUESTED" and "changes_requested"
			or nil
		local reviewer = pull_reviewer(node.author, decision or "pending", "participant")
		if reviewer then
			if state == "DISMISSED" then
				remove_reviewer(reviewers, reviewer)
			elseif decision then
				if requested[reviewer.provider_id:lower()] then
					reviewer.role = "reviewer"
				end
				upsert_reviewer(reviewers, reviewer)
			end
		end
	end

	for _, reviewer in ipairs(active) do
		upsert_reviewer(reviewers, reviewer)
	end
	return reviewers
end

---@param raw table
---@return "open"|"merged"|"declined"|"draft"
local function pull_state(raw)
	local raw_state = tostring(raw.state or ""):upper()
	if raw_state == "MERGED" then
		return "merged"
	elseif raw_state == "CLOSED" then
		return "declined"
	elseif raw.isDraft == true then
		return "draft"
	end
	return "open"
end

---@param raw any
---@param include_entries boolean|nil
---@return PullsStack|nil
local function pull_stack(raw, include_entries)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local stack = json.nilify(raw.stack)
	if type(stack) ~= "table" then
		return nil
	end
	local position = tonumber(raw.position)
	local size = tonumber(stack.size)
	if position == nil or size == nil then
		return nil
	end

	---@type PullsStack
	local result = {
		position = position,
		number = tonumber(stack.number),
		size = size,
		base_ref_name = json.safe_str(stack.baseRefName),
	}

	if include_entries then
		result.entries = {}
		for _, node in ipairs(github_mapper.connection_nodes(stack.entries)) do
			local entry = json.nilify(node)
			if type(entry) == "table" then
				---@type PullsStackEntry
				local item = { position = tonumber(entry.position) or 0 }
				local pr = json.nilify(entry.pullRequest)
				if type(pr) == "table" then
					item.number = tonumber(pr.number)
					item.title = json.safe_str(pr.title) or ""
					item.state = pull_state(pr)
				end
				table.insert(result.entries, item)
			end
		end
	end

	return result
end

---@param raw table
---@return GitHubPullRequest
function M.to_pull_request(raw)
	local number = tostring(raw.number or "")
	local author = pull_author(raw.author)
	local reviewers = M.to_reviewers(raw)
	local state = pull_state(raw)

	local raw_repository = json.safe_table(raw.repository)
	local owner, repo_name, repo_full_name = github_mapper.repository(raw_repository)
	local repository_url = json.safe_str(raw_repository.url)
	local https_url = repository_url
	if https_url and https_url ~= "" and not https_url:match("%.git$") then
		https_url = https_url .. ".git"
	end
	local first_commit = json.safe_table(json.safe_table(json.safe_table(raw.commits).nodes)[1])
	local commit = json.safe_table(first_commit.commit)
	local check_status = json.safe_str(json.safe_table(commit.statusCheckRollup).state)

	return {
		id = number,
		title = tostring(raw.title or ""),
		state = state,
		author = author,
		source = {
			branch = tostring(raw.headRefName or ""),
			commit_hash = tostring(raw.headRefOid or ""),
			fetch_ref = number ~= "" and string.format("refs/pull/%s/head", number) or nil,
		},
		destination = {
			branch = tostring(raw.baseRefName or ""),
			commit_hash = tostring(raw.baseRefOid or ""),
			https_url = https_url,
			ssh_url = json.safe_str(raw_repository.sshUrl),
		},
		comments_count = tonumber(raw.totalCommentsCount) or 0,
		created_on = tostring(raw.createdAt or ""),
		updated_on = tostring(raw.updatedAt or ""),
		link = {
			html = tostring(raw.url or ""),
		},
		provider = "github",
		repo = {
			id = repo_full_name,
			name = repo_name,
			owner = owner,
			repo_name = repo_name,
			full_name = repo_full_name,
			html_url = repository_url,
		},
		repo_full_name = repo_full_name,
		reviewers = reviewers,
		stack = pull_stack(raw.stackEntry),
		node_id = json.safe_str(raw.id),
		review_decision = json.safe_str(raw.reviewDecision),
		check_status = check_status,
		lines_added = tonumber(raw.additions) or 0,
		lines_removed = tonumber(raw.deletions) or 0,
	}
end

---@param raw table
---@return GitHubPullRequestDetails
function M.to_pull_request_details(raw)
	---@type GitHubPullRequestDetails
	local details = {
		description = json.safe_str(raw.body) or "",
		reactions = github_mapper.graphql_reactions(raw.reactionGroups),
		assignees = pull_assignees(raw) or {},
		labels = pull_labels(raw) or {},
		stack = pull_stack(raw.stackEntry, true),
	}
	local subscription = tostring(raw.viewerSubscription or "")
	if subscription ~= "" then
		details.is_subscribed = subscription == "SUBSCRIBED"
	end
	return details
end

---@param nodes table[]
---@return PullRequest[]
function M.to_search_results_from_graphql(nodes)
	local out = {}
	for _, raw in ipairs(nodes) do
		if raw.number ~= nil then
			table.insert(out, M.to_pull_request(raw))
		end
	end
	return out
end

---@param node table GraphQL pull request timeline item
---@return PullsActivityEntry|nil
function M.to_activity(node)
	local event = json.safe_str(node.__typename) or ""
	local entry = {
		actor = actor_from_login(json.safe_str(json.safe_table(node.actor).login) or ""),
		date = json.safe_str(node.createdAt) or "",
	}

	if event == "PullRequestReview" then
		local state = (json.safe_str(node.state) or ""):lower()
		if state == "pending" then
			return nil
		end
		entry.actor = actor_from_login(json.safe_str(json.safe_table(node.author).login) or "")
		entry.date = json.safe_str(node.submittedAt) or ""
		entry.kind = state == "approved" and "approval"
			or state == "changes_requested" and "changes_requested"
			or "review"
		entry.label = entry.kind == "approval" and "approved"
			or entry.kind == "changes_requested" and "requested changes"
			or "left a review"
		local body = body_text(node.body)
		entry.body = body ~= "" and body or nil
	elseif event == "ReviewDismissedEvent" then
		entry.kind = "review_dismissed"
		entry.label = "dismissed their review"
	elseif event == "ClosedEvent" or event == "MergedEvent" or event == "ReopenedEvent" then
		entry.kind = event == "ClosedEvent" and "closed" or event == "MergedEvent" and "merged" or "reopened"
		entry.label = entry.kind
	elseif event == "HeadRefForcePushedEvent" then
		entry.kind = "force_pushed"
		entry.label = "force pushed"
	elseif event == "BaseRefForcePushedEvent" then
		entry.kind = "force_pushed"
		entry.label = "base branch force pushed"
	elseif event == "PullRequestCommit" then
		local commit = json.safe_table(node.commit)
		local author = json.safe_table(commit.author)
		local msg = (json.safe_str(commit.message) or ""):match("([^\n]+)") or ""
		local sha = (json.safe_str(commit.oid) or ""):sub(1, 8)
		entry.kind = "committed"
		entry.actor = actor_from_login(json.safe_str(author.name) or "")
		entry.date = json.safe_str(commit.authoredDate) or ""
		entry.label = sha ~= "" and string.format("%s %s", sha, msg) or msg
	elseif event == "LabeledEvent" or event == "UnlabeledEvent" then
		local label = json.safe_str(json.safe_table(node.label).name) or ""
		if label == "" then
			return nil
		end
		entry.kind = event == "LabeledEvent" and "labeled" or "unlabeled"
		entry.label = (event == "LabeledEvent" and "added label" or "removed label") .. ": " .. label
	elseif event == "AssignedEvent" or event == "UnassignedEvent" then
		local assignee = json.safe_str(json.safe_table(node.assignee).login) or ""
		if assignee == "" then
			return nil
		end
		entry.kind = event == "AssignedEvent" and "assigned" or "unassigned"
		entry.label = entry.kind .. " " .. assignee
	elseif event == "ReviewRequestedEvent" then
		local reviewer = json.safe_str(json.safe_table(node.requestedReviewer).login) or ""
		entry.kind = "review_requested"
		entry.label = reviewer ~= "" and ("requested review from " .. reviewer) or "requested review"
	elseif event == "RenamedTitleEvent" then
		entry.kind = "renamed"
		entry.label = "changed the title"
		entry.body =
			string.format("%s → %s", json.safe_str(node.previousTitle) or "", json.safe_str(node.currentTitle) or "")
	elseif event == "CommentDeletedEvent" then
		entry.kind = "comment_deleted"
		entry.label = "deleted a comment"
	elseif event == "ReadyForReviewEvent" then
		entry.kind = "ready_for_review"
		entry.label = "marked as ready for review"
	elseif event == "ConvertToDraftEvent" then
		entry.kind = "convert_to_draft"
		entry.label = "marked as draft"
	else
		return nil
	end
	return entry
end

---@param node table GraphQL `IssueComment`
---@param author_login string|nil
---@return PullsComment
function M.to_comment(node, author_login)
	return {
		id = node.id,
		author = comment_author(node.author),
		author_roles = github_mapper.author_roles(node, author_login),
		body = body_text(node.body),
		created_at = json.safe_str(node.createdAt) or "",
		url = json.safe_str(node.url) or "",
		reactions = github_mapper.graphql_reactions(node.reactionGroups),
	}
end

---@param raw table GraphQL `PullRequest`
---@param author_login string|nil
---@return PullsComment|nil
function M.to_description(raw, author_login)
	if json.nilify(raw.id) == nil then
		return nil
	end
	return M.to_comment(raw, author_login)
end

---@param node table GraphQL `PullRequestReview`
---@return PullsReviewHistoryEntry|nil
function M.to_conversation_review(node)
	local body = body_text(node.body)
	local state = (json.safe_str(node.state) or ""):lower()
	if vim.trim(body) == "" or state == "pending" then
		return nil
	end
	if state ~= "approved" and state ~= "changes_requested" and state ~= "commented" and state ~= "dismissed" then
		state = "reviewed"
	end

	return {
		id = json.safe_str(node.id),
		author = comment_author(node.author),
		state = state,
		submitted_on = json.safe_str(node.submittedAt) or "",
		body = body,
		commit_hash = json.safe_str(json.safe_table(node.commit).oid),
		url = json.safe_str(node.url),
	}
end

---@param node table GraphQL `PullRequestReviewComment`
---@param thread table GraphQL `PullRequestReviewThread`
---@param fallback_parent number|string|nil
---@param author_login string|nil
---@return PullsComment
function M.to_review_comment(node, thread, fallback_parent, author_login)
	local path = json.safe_str(thread.path)
	local anchor = json.nilify(thread.line) or json.nilify(thread.originalLine)
	local start_line = json.nilify(thread.startLine) or json.nilify(thread.originalStartLine)
	local start_side = json.nilify(thread.startDiffSide) or thread.diffSide

	local file, inline
	if path then
		local old = thread.diffSide == "LEFT"
		if thread.subjectType == "FILE" then
			file = { path = path }
		elseif anchor then
			if start_line == anchor then
				start_line = nil
			end
			inline = {
				path = path,
				from = old and anchor or nil,
				to = not old and anchor or nil,
				start_from = start_side == "LEFT" and start_line or nil,
				start_to = start_side ~= "LEFT" and start_line or nil,
			}
		end
	end

	local reply_to = json.nilify(node.replyTo)
	local resolved = thread.isResolved == true
	local outdated = thread.isOutdated == true
	local result = {
		id = node.id,
		author = comment_author(node.author),
		author_roles = github_mapper.author_roles(node, author_login),
		body = body_text(node.body),
		created_at = json.safe_str(node.createdAt) or "",
		url = json.safe_str(node.url) or "",
		parent_id = reply_to and reply_to.id or fallback_parent,
		file = file,
		inline = inline,
		pending = json.safe_table(node.pullRequestReview).state == "PENDING",
		outdated = outdated,
		state = resolved and "RESOLVED" or (outdated and "OUTDATED" or nil),
		reactions = github_mapper.graphql_reactions(node.reactionGroups),
		thread_id = json.safe_str(thread.id),
	}
	local resolved_by = comment_author(json.nilify(thread.resolvedBy))
	if result.parent_id == nil and resolved and resolved_by.username ~= "" then
		result.resolved_by = resolved_by
	end
	return result
end

---@param node table GraphQL `PullRequestReviewComment` returned by a mutation, which has no thread
---@param sibling PullsComment A comment from the same thread
---@param parent_id number|string|nil
---@param author_login string|nil
---@return PullsComment
function M.to_thread_comment(node, sibling, parent_id, author_login)
	local result = M.to_review_comment(node, { id = sibling.thread_id }, parent_id, author_login)
	result.file = sibling.file
	result.inline = sibling.inline
	result.outdated = sibling.outdated
	result.state = sibling.state
	return result
end

return M
