local M = {}

local json = require("atlas.core.json")
local github_mapping = require("atlas.providers.github.mapping")

---@param value any
---@return string
local function body_text(value)
	return json.safe_str(value) or ""
end

---@param login string
---@return PullsAuthor|nil
local function actor_from_login(login)
	if login == "" then
		return nil
	end
	return { name = login, id = "", username = login, nickname = login }
end

---@param raw any
---@return PullsAuthor
local function pull_author(raw)
	local user = github_mapping.identity(raw) or { id = "", login = "", name = "" }
	return { name = user.name, id = user.id, username = user.login, nickname = user.login }
end

---@param raw any
---@return PullsAuthor
local function comment_author(raw)
	local user = github_mapping.identity(raw) or { id = "", login = "" }
	return { name = user.login, id = user.id, username = user.login, nickname = user.login }
end

---@param raw table
---@return PullsAuthor[]|nil
local function pull_assignees(raw)
	if json.nilify(raw.assignees) == nil then
		return nil
	end

	local assignees = {}
	for _, node in ipairs(github_mapping.connection_nodes(raw.assignees)) do
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
	for _, node in ipairs(github_mapping.connection_nodes(raw.labels)) do
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
	local left_provider = tostring(left.provider_id or "")
	local right_provider = tostring(right.provider_id or "")
	if left_provider ~= "" and right_provider ~= "" then
		return left_provider:lower() == right_provider:lower()
	end

	local left_id = tostring(left.id or "")
	local right_id = tostring(right.id or "")
	if left_id ~= "" and right_id ~= "" then
		return left_id == right_id
	end

	local left_username = tostring(left.username or "")
	local right_username = tostring(right.username or "")
	return left_username ~= "" and right_username ~= "" and left_username:lower() == right_username:lower()
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

---@param raw any
---@param decision "approved"|"changes_requested"|"pending"
---@return PullsReviewer|nil
local function pull_reviewer(raw, decision)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local user = github_mapping.identity(raw) or { id = "", login = "", name = "" }
	local slug = json.safe_str(raw.slug) or ""
	local combined_slug = json.safe_str(raw.combinedSlug) or ""
	local organization = json.nilify(raw.organization)
	local organization_login = type(organization) == "table" and (json.safe_str(organization.login) or "") or ""
	local team = combined_slug ~= "" and combined_slug
		or (organization_login ~= "" and slug ~= "" and organization_login .. "/" .. slug or slug)
	local username = user.login ~= "" and user.login or team
	if username == "" then
		return nil
	end
	local name = user.name ~= "" and user.name or (json.safe_str(raw.name) or username)

	return {
		id = user.id ~= "" and user.id or username,
		provider_id = username,
		name = name,
		username = username,
		nickname = username,
		decision = decision,
	}
end

---@param raw table
---@return PullRequest
function M.to_pull_request(raw)
	local number = tostring(raw.number or "")
	local author = pull_author(raw.author)

	local has_reviews = json.nilify(raw.latestOpinionatedReviews) ~= nil
	local has_requests = json.nilify(raw.reviewRequests) ~= nil
	local reviewers = (has_reviews or has_requests) and {} or nil
	local review_decisions = has_reviews and {} or nil
	local requested = {}
	for _, node in ipairs(github_mapping.connection_nodes(raw.reviewRequestEvents)) do
		local reviewer = pull_reviewer(node.requestedReviewer, "pending")
		if reviewer then
			requested[reviewer.id] = true
		end
	end

	local active = {}
	for _, node in ipairs(github_mapping.connection_nodes(raw.reviewRequests)) do
		local reviewer = pull_reviewer(node.requestedReviewer or node, "pending")
		if reviewer then
			requested[reviewer.id] = true
			table.insert(active, reviewer)
		end
	end

	local function add_review(node)
		local state = tostring(node.state or ""):upper()
		local decision = state == "APPROVED" and "approved"
			or state == "CHANGES_REQUESTED" and "changes_requested"
			or nil
		local reviewer = decision and pull_reviewer(node.author, decision) or nil
		if reviewer then
			local target = requested[reviewer.id] and reviewers or review_decisions
			upsert_reviewer(target, reviewer)
		end
	end

	for _, node in ipairs(github_mapping.connection_nodes(raw.latestOpinionatedReviews)) do
		add_review(node)
	end
	for _, reviewer in ipairs(active) do
		upsert_reviewer(reviewers, reviewer)
	end

	local state = "open"
	local raw_state = tostring(raw.state or ""):upper()
	if raw_state == "MERGED" then
		state = "merged"
	elseif raw_state == "CLOSED" then
		state = "declined"
	elseif raw.isDraft == true then
		state = "draft"
	end

	local owner, repo_name, repo_full_name = github_mapping.repository(raw.repository)
	local repository_url = json.safe_str((raw.repository or {}).url)
	if repository_url and repository_url ~= "" and not repository_url:match("%.git$") then
		repository_url = repository_url .. ".git"
	end

	return {
		id = number,
		title = tostring(raw.title or ""),
		description = tostring(raw.body or ""),
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
			https_url = repository_url,
			ssh_url = json.safe_str((raw.repository or {}).sshUrl),
		},
		comments_count = tonumber(raw.totalCommentsCount)
			or tonumber(raw.commentsCount)
			or (type(raw.comments) == "table" and tonumber(raw.comments.totalCount))
			or (type(raw.comments) == "table" and #raw.comments)
			or tonumber(raw.comments)
			or 0,
		tasks_count = 0,
		created_on = tostring(raw.createdAt or ""),
		updated_on = tostring(raw.updatedAt or ""),
		link = {
			html = tostring(raw.url or ""),
		},
		provider = "github",
		workspace = owner,
		repo = repo_name,
		repo_full_name = repo_full_name,
		is_subscribed = tostring(raw.viewerSubscription or "") == "SUBSCRIBED",
		reactions = github_mapping.reaction_groups(raw.reactionGroups),
		assignees = pull_assignees(raw),
		reviewers = reviewers,
		review_decisions = review_decisions,
		labels = pull_labels(raw),
		lines_added = tonumber(raw.additions),
		lines_removed = tonumber(raw.deletions),
		_raw = {
			node_id = json.safe_str(raw.id),
			commits = json.nilify(raw.commits),
			review_decision = json.safe_str(raw.reviewDecision),
		},
	}
end

---@param raw table
---@return PullsUser
function M.to_user(raw)
	local user = github_mapping.identity(raw) or { id = "", login = "", name = "" }
	return {
		name = user.name,
		id = user.id,
		username = user.login,
	}
end

---@param nodes table[]
---@return PullRequest[]
function M.to_search_results_from_graphql(nodes)
	local out = {}
	for _, raw in ipairs(nodes or {}) do
		if raw.number ~= nil then
			table.insert(out, M.to_pull_request(raw))
		end
	end
	return out
end

---@param item table
---@return PullsActivityEntry|nil
function M.to_activity(item)
	local event = tostring(item.event or "")
	local actor_login = (type(item.actor) == "table" and tostring(item.actor.login or ""))
		or (type(item.user) == "table" and tostring(item.user.login or ""))
		or ""
	local actor = actor_from_login(actor_login)
	local date = tostring(item.created_at or item.submitted_at or "")

	if event == "commented" then
		local body = body_text(item.body)
		return {
			kind = "comment",
			actor = actor,
			date = date,
			label = "commented",
			body = body ~= "" and body or nil,
		}
	elseif event == "reviewed" then
		local state_label = tostring(item.state or ""):lower()
		if state_label == "pending" then
			return nil
		end
		local kind = state_label == "approved" and "approval"
			or state_label == "changes_requested" and "changes_requested"
			or "review"
		local verb = kind == "approval" and "approved"
			or kind == "changes_requested" and "requested changes"
			or "left a review"
		local body = body_text(item.body)
		return {
			kind = kind,
			actor = actor,
			date = date,
			label = verb,
			body = body ~= "" and body or nil,
		}
	elseif event == "review_dismissed" then
		return {
			kind = "review_dismissed",
			actor = actor,
			date = date,
			label = "dismissed their review",
		}
	elseif event == "closed" or event == "merged" or event == "reopened" then
		return { kind = event, actor = actor, date = date, label = event }
	elseif event == "head_ref_force_pushed" then
		return { kind = "force_pushed", actor = actor, date = date, label = "force pushed" }
	elseif event == "committed" then
		local author = type(item.author) == "table" and item.author or {}
		local author_name = tostring(author.name or "")
		local msg = tostring(item.message or ""):match("([^\n]+)") or ""
		local sha = tostring(item.sha or ""):sub(1, 8)
		return {
			kind = "committed",
			actor = actor_from_login(author_name),
			date = tostring(author.date or date),
			label = sha ~= "" and string.format("%s %s", sha, msg) or msg,
		}
	elseif event == "base_ref_force_pushed" then
		return { kind = "force_pushed", actor = actor, date = date, label = "base branch force pushed" }
	elseif event == "labeled" or event == "unlabeled" then
		local label = type(item.label) == "table" and tostring(item.label.name or "") or ""
		if label == "" then
			return nil
		end
		local verb = event == "labeled" and "added label" or "removed label"
		return { kind = event, actor = actor, date = date, label = verb .. ": " .. label }
	elseif event == "assigned" or event == "unassigned" then
		local assignee = type(item.assignee) == "table" and tostring(item.assignee.login or "") or ""
		if assignee == "" then
			return nil
		end
		local verb = event == "assigned" and "assigned" or "unassigned"
		return { kind = event, actor = actor, date = date, label = verb .. " " .. assignee }
	elseif event == "review_requested" then
		local reviewer = type(item.requested_reviewer) == "table" and tostring(item.requested_reviewer.login or "")
			or ""
		return {
			kind = "review_requested",
			actor = actor,
			date = date,
			label = reviewer ~= "" and ("requested review from " .. reviewer) or "requested review",
		}
	elseif event == "renamed" then
		local rename = item.rename or {}
		return {
			kind = "renamed",
			actor = actor,
			date = date,
			label = "changed the title",
			body = string.format("%s → %s", tostring(rename.from or ""), tostring(rename.to or "")),
		}
	elseif event == "comment_deleted" then
		return {
			kind = "comment_deleted",
			actor = actor,
			date = date,
			label = "deleted a comment",
		}
	elseif event == "ready_for_review" then
		return {
			kind = "ready_for_review",
			actor = actor,
			date = date,
			label = "marked as ready for review",
		}
	elseif event == "convert_to_draft" then
		return { kind = "convert_to_draft", actor = actor, date = date, label = "marked as draft" }
	end
	return nil
end

---@param raw table
---@param raw_user table|nil
---@return PullsComment
local function comment(raw, raw_user)
	return {
		id = raw.id,
		parent_id = nil,
		author = comment_author(raw_user),
		content_raw = body_text(raw.body),
		created_on = tostring(raw.created_at or raw.submitted_at or ""),
		inline = nil,
		url = nil,
		html_url = tostring(raw.html_url or ""),
		reactions = github_mapping.reaction_counts(raw.reactions),
	}
end

---@param raw table
---@return PullsComment
function M.to_activity_comment(raw)
	local raw_user = type(raw.user) == "table" and raw.user or (type(raw.actor) == "table" and raw.actor or nil)
	local result = comment(raw, raw_user)
	result.parent_id = nil
	result.inline = nil
	return result
end

---@param raw table
---@return PullsReviewHistoryEntry|nil
function M.to_conversation_review(raw)
	local body = body_text(raw.body)
	if vim.trim(body) == "" then
		return nil
	end

	local raw_user = type(raw.user) == "table" and raw.user or (type(raw.actor) == "table" and raw.actor or nil)
	local node_id = json.safe_str(raw.node_id)
	local state = tostring(raw.state or ""):lower()
	if state ~= "approved" and state ~= "changes_requested" and state ~= "commented" and state ~= "dismissed" then
		state = "reviewed"
	end

	return {
		id = node_id,
		author = comment_author(raw_user),
		state = state,
		submitted_on = tostring(raw.submitted_at or raw.created_at or ""),
		body = body,
		commit_hash = json.safe_str(raw.commit_id),
		url = json.safe_str(raw.html_url),
	}
end

---@param raw table
---@param thread_state {pending: boolean|nil, resolved: boolean, outdated: boolean}|nil
---@return PullsComment
function M.to_comment(raw, thread_state)
	local line = json.nilify(raw.line)
	local original_line = json.nilify(raw.original_line)
	local start_line = json.nilify(raw.start_line) or json.nilify(raw.original_start_line)
	local start_side = json.nilify(raw.start_side) or raw.side
	local path = json.nilify(raw.path)
	local subject_type = tostring(raw.subject_type or ""):upper()

	local file, inline
	if path ~= nil then
		local side = raw.side == "LEFT" and "old" or "new"
		local anchor = line or original_line
		if subject_type == "FILE" then
			file = { path = tostring(path) }
		elseif anchor then
			if start_line == anchor then
				start_line = nil
			end
			inline = {
				path = tostring(path),
				from = side == "old" and anchor or nil,
				to = side == "new" and anchor or nil,
				start_from = start_side == "LEFT" and start_line or nil,
				start_to = start_side ~= "LEFT" and start_line or nil,
			}
		end
	end

	local result = comment(raw, type(raw.user) == "table" and raw.user or nil)
	result.parent_id = json.nilify(raw.in_reply_to_id)
	result.file = file
	result.inline = inline
	result.is_task = nil
	if thread_state then
		result.outdated = thread_state.outdated == true
		if thread_state.pending then
			result.state = "PENDING"
		elseif thread_state.resolved then
			result.state = "RESOLVED"
		elseif thread_state.outdated then
			result.state = "OUTDATED"
		end
	end
	return result
end

---@param node table
---@param thread table
---@param fallback_parent number|string|nil
---@return PullsComment
function M.to_review_comment(node, thread, fallback_parent)
	local author = json.nilify(node.author) or {}
	local reply_to = json.nilify(node.replyTo)
	local review = json.safe_table(node.pullRequestReview)
	local original_line = json.nilify(thread.originalLine) or json.nilify(node.originalLine)
	local result = M.to_comment({
		id = node.databaseId,
		in_reply_to_id = reply_to and reply_to.databaseId or nil,
		user = { login = author.login, id = author.databaseId },
		body = node.body,
		path = thread.path or node.path,
		subject_type = thread.subjectType or node.subjectType,
		line = thread.line or node.line,
		start_line = thread.startLine or node.startLine,
		original_line = original_line,
		original_start_line = thread.originalStartLine or node.originalStartLine,
		side = thread.diffSide,
		start_side = thread.startDiffSide,
		url = node.url,
		html_url = node.url,
		created_at = node.createdAt,
		reactions = github_mapping.reaction_groups(node.reactionGroups),
	}, {
		pending = review.state == "PENDING",
		resolved = thread.isResolved == true,
		outdated = thread.isOutdated == true,
	})
	result.thread_id = json.safe_str(thread.id)
	result._raw = {
		comment_id = tostring(node.id or ""),
		original_line = original_line,
	}
	if result.parent_id == nil then
		result.parent_id = fallback_parent
	end
	if result.parent_id == nil and thread.isResolved == true and type(json.nilify(thread.resolvedBy)) == "table" then
		result.resolved_by = comment_author(thread.resolvedBy)
	end
	return result
end

---@param comment PullsComment
---@return table
function M.review_thread(comment)
	local inline = comment.inline or {}
	local file = comment.file
	local side = not file and (inline.to ~= nil and "RIGHT" or "LEFT") or nil
	local start_side = not file and (inline.start_to ~= nil and "RIGHT" or (inline.start_from ~= nil and "LEFT" or nil))
		or nil
	return {
		id = tostring(comment.thread_id or ""),
		subjectType = file and "FILE" or "LINE",
		path = file and file.path or inline.path,
		line = inline.to,
		startLine = inline.start_to,
		originalLine = (comment._raw or {}).original_line or inline.from,
		originalStartLine = inline.start_from,
		diffSide = side,
		startDiffSide = start_side,
		isResolved = comment.state == "RESOLVED",
		isOutdated = comment.outdated == true or comment.state == "OUTDATED",
	}
end

---@param raw table
---@return PullsComment[]
function M.to_tasks(raw)
	local out = {}
	for _, line in ipairs(vim.split(tostring(raw.body or ""), "\n", { plain = true })) do
		local marker = line:match("^%s*[-*+]%s+%[([ xX])%]") or line:match("^%s*%[([ xX])%]")
		if marker then
			local task = M.to_comment(raw)
			task.id = string.format("github-task:%s:%06d", tostring(raw.id), #out + 1)
			task.content_raw = line
			task.is_task = true
			task.task_label = "Checklist"
			task.state = marker:lower() == "x" and "RESOLVED" or nil
			table.insert(out, task)
		end
	end
	return out
end

return M
