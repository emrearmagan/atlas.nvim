local json = require("atlas.core.json")
local diff_parser = require("atlas.core.git.diff_parser")

local M = {}

---@param raw table
---@return PullsAuthor
local function author(raw)
	local login = raw.login
	local name = raw.full_name or ""
	return {
		id = tostring(raw.id or ""),
		name = name ~= "" and name or login,
		username = login,
		nickname = login,
	}
end

---@param values table[]
---@return PullsAuthor[]
local function authors(values)
	local result = {}
	for _, value in ipairs(values) do
		table.insert(result, author(value))
	end
	return result
end

---@param values table[]
---@return PullsReviewer[]
local function reviewers(values)
	local result = {}
	for _, value in ipairs(authors(values)) do
		table.insert(result, {
			id = value.id,
			provider_id = value.username,
			name = value.name,
			username = value.username,
			nickname = value.nickname,
			role = "reviewer",
			decision = "pending",
		})
	end
	return result
end

---@param value string|nil
---@return string|nil
local function nonempty(value)
	local result = json.nilify(value) or ""
	return result ~= "" and result or nil
end

---@param raw table|nil
---@param field string
---@return string|nil
local function object_name(raw, field)
	raw = json.nilify(raw)
	return raw and nonempty(raw[field]) or nil
end

---@param before string|nil
---@param after string|nil
---@return string|nil
local function change(before, after)
	if before and after then
		return before .. " → " .. after
	end
	return after or before
end

---@param raw table
---@return "open"|"merged"|"declined"|"draft"
local function state(raw)
	if raw.merged == true then
		return "merged"
	end
	if raw.state == "closed" then
		return "declined"
	end
	if raw.draft == true then
		return "draft"
	end
	return "open"
end

---@param value integer|nil
---@return integer|nil
local function positive_line(value)
	local line = json.nilify(value)
	return line and line > 0 and line or nil
end

---@param raw table
---@return { from: integer|nil, to: integer|nil, start_from: integer|nil, start_to: integer|nil }
function M.review_lines(raw)
	local lines = {
		from = positive_line(raw.original_position),
		to = positive_line(raw.position),
	}
	local extra_lines = json.nilify(raw.extra_lines_count) or 0
	if extra_lines > 0 and lines.from then
		lines.start_from = lines.from
		lines.from = lines.from + extra_lines
	elseif extra_lines > 0 and lines.to then
		lines.start_to = lines.to
		lines.to = lines.to + extra_lines
	end
	return lines
end

---@param raw table
---@param lines { from: integer|nil, to: integer|nil, start_from: integer|nil, start_to: integer|nil }
---@return PullsInlineCommentPosition|nil, DiffHunk|nil
local function inline_position(raw, lines)
	local path = raw.path or ""
	local from, to = lines.from, lines.to
	local start_from, start_to = lines.start_from, lines.start_to
	if path == "" or (from == nil and to == nil) then
		return nil, nil
	end

	local inline = {
		path = path,
		from = from,
		to = to,
		start_from = start_from,
		start_to = start_to,
		commit_hash = json.nilify(raw.commit_id),
	}
	local diff_hunk = json.nilify(raw.diff_hunk)
	if not diff_hunk or diff_hunk == "" then
		return inline, nil
	end

	local synthetic = "diff --git a/x b/x\n--- a/x\n+++ b/x\n" .. diff_hunk .. "\n"
	local files = diff_parser.parse(synthetic) ---@type DiffFile[]
	local hunk = files[1] and files[1].hunks[1] or nil
	local anchor = to or from
	if hunk and anchor then
		hunk = diff_parser.window_hunk(hunk, to and "new" or "old", anchor)
	end
	return inline, hunk
end

M.author = author
M.pull_state = state

local review_history_states = {
	APPROVED = "approved",
	REQUEST_CHANGES = "changes_requested",
	COMMENT = "commented",
}

---@param pr PullRequest
---@param raw_reviews table[]
---@return { reviewers: PullsReviewer[], raw: table[], pending_requests: integer, history: PullsReviewHistoryEntry[] }
function M.to_review_data(pr, raw_reviews)
	local latest_opinion, latest_request, latest_team_request = {}, {}, {}
	local configured_reviewers = {}
	for _, reviewer in ipairs(pr.reviewers or {}) do
		if reviewer.id ~= "" then
			configured_reviewers[reviewer.id] = reviewer
		end
	end

	local history = {}
	for _, review in ipairs(raw_reviews) do
		local review_id = tonumber(review.id)
		local review_state = tostring(review.state or ""):upper()
		local is_opinion = review_state == "APPROVED" or review_state == "REQUEST_CHANGES"
		local is_request = review_state == "REQUEST_REVIEW"
		local user = json.nilify(review.user)
		local team = json.nilify(review.team)
		local mapped_author = user and author(user) or nil

		if (is_opinion or is_request) and mapped_author then
			local key = mapped_author.id
			local target = is_request and latest_request or latest_opinion
			local previous = target[key]
			if key ~= "" and (not previous or review_id > previous.id) then
				target[key] = { id = review_id, raw = review }
			end
		elseif is_request and team then
			local key = tostring(team.id or team.name or "")
			local previous = latest_team_request[key]
			if key ~= "" and (not previous or review_id > previous.id) then
				latest_team_request[key] = { id = review_id, raw = review }
			end
		end

		local history_state = review.dismissed == true and "dismissed" or review_history_states[review_state]
		local body = json.nilify(review.body)
		if body and vim.trim(body) == "" then
			body = nil
		end
		if history_state and not (history_state == "commented" and body == nil) then
			table.insert(history, {
				id = tostring(review.id),
				author = mapped_author,
				state = history_state,
				submitted_on = nonempty(review.dismissed == true and review.updated_at or review.submitted_at) or "",
				body = body,
				commit_hash = nonempty(review.commit_id),
				url = nonempty(review.html_url),
			})
		end
	end

	local reviewers_result, latest_reviews, keys = {}, {}, {}
	for key in pairs(latest_opinion) do
		keys[key] = true
	end
	for key in pairs(latest_request) do
		keys[key] = true
	end
	for key in pairs(configured_reviewers) do
		keys[key] = true
	end
	for key in pairs(keys) do
		local opinion = latest_opinion[key]
		local request = latest_request[key]
		local configured = configured_reviewers[key]
		local active_opinion = opinion and opinion.raw.dismissed ~= true and opinion or nil
		local active_request = request and request.raw.dismissed ~= true and request or nil
		local current = active_opinion
		if active_request and (not current or active_request.id > current.id) then
			current = active_request
		end
		if current then
			local review = current.raw
			local review_state = tostring(review.state or ""):upper()
			local mapped_author = author(review.user)
			local role = (configured or active_request) and "reviewer" or "participant"
			local decision = review_state == "APPROVED" and "approved"
				or (review_state == "REQUEST_CHANGES" and "changes_requested" or "reviewed")
			if review_state == "REQUEST_REVIEW" or review.stale == true then
				decision = role == "reviewer" and "pending" or "reviewed"
			end
			table.insert(reviewers_result, {
				id = mapped_author.id,
				provider_id = mapped_author.username,
				name = mapped_author.name,
				username = mapped_author.username,
				nickname = mapped_author.nickname,
				role = role,
				decision = decision,
			})
			table.insert(latest_reviews, review)
		elseif configured then
			table.insert(reviewers_result, {
				id = configured.id,
				provider_id = configured.provider_id,
				name = configured.name,
				username = configured.username,
				nickname = configured.nickname,
				role = "reviewer",
				decision = "pending",
			})
		end
	end

	table.sort(reviewers_result, function(left, right)
		return left.provider_id < right.provider_id
	end)
	local pending_requests = 0
	for _, reviewer in ipairs(reviewers_result) do
		if reviewer.decision == "pending" then
			pending_requests = pending_requests + 1
		end
	end
	for _, request in pairs(latest_team_request) do
		if request.raw.dismissed ~= true and tostring(request.raw.state or ""):upper() == "REQUEST_REVIEW" then
			pending_requests = pending_requests + 1
			table.insert(latest_reviews, request.raw)
		end
	end
	table.sort(latest_reviews, function(left, right)
		return tonumber(left.id) < tonumber(right.id)
	end)
	table.sort(history, function(left, right)
		if left.submitted_on ~= right.submitted_on then
			return left.submitted_on < right.submitted_on
		end
		return tostring(left.id or "") < tostring(right.id or "")
	end)

	return {
		reviewers = reviewers_result,
		raw = latest_reviews,
		pending_requests = pending_requests,
		history = history,
	}
end

---@param repository table
---@return string|nil https_url, string|nil ssh_url
local function clone_urls(repository)
	return nonempty(repository.clone_url), nonempty(repository.ssh_url)
end

---@param raw table
---@return PullsAuthor[]
local function pull_assignees(raw)
	local result = authors(json.nilify(raw.assignees) or {})
	if #result == 0 and json.nilify(raw.assignee) then
		table.insert(result, author(raw.assignee))
	end
	return result
end

---@param raw table
---@return PullsLabel[], integer[]
local function pull_labels(raw)
	local labels, ids = {}, {}
	for _, value in ipairs(json.nilify(raw.labels) or {}) do
		local name = value.name
		if name and name ~= "" then
			table.insert(labels, {
				name = name,
				color = (value.color or ""):gsub("^#", ""),
			})
		end
		if value.id then
			table.insert(ids, value.id)
		end
	end
	return labels, ids
end

---@param raw table
---@return ForgejoPullRequest
function M.to_pull_request(raw)
	local number = raw.number

	local base = json.safe_table(raw.base)
	local head = json.safe_table(raw.head)
	local base_repo = json.safe_table(base.repo)
	local head_repo = json.safe_table(head.repo)
	local slug = base_repo.full_name or ""
	local workspace, repo = slug:match("^([^/]+)/([^/]+)$")
	local source_slug = tostring(head_repo.full_name or "")
	local source_is_fork = source_slug ~= "" and slug ~= "" and source_slug ~= slug
	local source_https_url, source_ssh_url = clone_urls(head_repo)
	local destination_https_url, destination_ssh_url = clone_urls(base_repo)
	return {
		id = number,
		title = raw.title or "",
		state = state(raw),
		author = author(raw.user),
		source = {
			branch = head.ref or "",
			commit_hash = head.sha or "",
			fetch_ref = not source_is_fork and string.format("refs/pull/%d/head", number) or nil,
			https_url = source_is_fork and source_https_url or nil,
			ssh_url = source_is_fork and source_ssh_url or nil,
		},
		destination = {
			branch = base.ref or "",
			commit_hash = base.sha or "",
			https_url = destination_https_url,
			ssh_url = destination_ssh_url,
		},
		comments_count = (raw.comments or 0) + (raw.review_comments or 0),
		created_on = raw.created_at or "",
		updated_on = raw.updated_at or "",
		link = { html = raw.html_url or "" },
		provider = "forgejo",
		workspace = workspace,
		repo = repo,
		repo_full_name = slug,
		reviewers = reviewers(json.nilify(raw.requested_reviewers) or {}),
		lines_added = raw.additions,
		lines_removed = raw.deletions,
		mergeable = json.nilify(raw.mergeable),
		merge_base = json.nilify(raw.merge_base),
	}
end

---@param raw any
---@return ForgejoPullRequestDetails
function M.to_pull_request_details(raw)
	local labels, label_ids = pull_labels(raw)
	return {
		description = json.nilify(raw.body) or "",
		is_subscribed = json.nilify(raw.subscribed),
		assignees = pull_assignees(raw),
		labels = labels,
		label_ids = label_ids,
	}
end

---@param values table[]
---@return ForgejoPullRequest[]
function M.to_pull_requests(values)
	local prs = {}
	for _, raw in ipairs(values) do
		table.insert(prs, M.to_pull_request(raw))
	end
	return prs
end

---@param raw table
---@return ForgejoPullRequest
function M.to_search_pull_request(raw)
	local metadata = raw.pull_request
	local repository = raw.repository
	local slug = tostring(repository.full_name or "")

	local normalized = {}
	for key, value in pairs(raw) do
		normalized[key] = value
	end
	normalized.merged = metadata.merged
	normalized.draft = metadata.draft
	normalized.html_url = metadata.html_url
	normalized.base = { repo = { full_name = slug } }
	normalized.head = { repo = repository }
	return M.to_pull_request(normalized)
end

---@param raw table
---@param review table|nil
---@param lines { from: integer|nil, to: integer|nil, start_from: integer|nil, start_to: integer|nil }|nil
---@return PullsComment
function M.to_comment(raw, review, lines)
	review = json.nilify(review)
	local inline, inline_hunk = inline_position(raw, lines or M.review_lines(raw))
	local review_state = review and tostring(review.state or ""):upper() or ""
	local resolver = json.nilify(raw.resolver)
	local comment_state = resolver and "RESOLVED"
		or (review_state == "PENDING" and "PENDING")
		or (review and review.stale == true and "OUTDATED")
		or nil
	local outdated = review ~= nil and review.stale == true
	return {
		id = raw.id,
		parent_id = nil,
		author = raw.user and author(raw.user) or nil,
		content_raw = raw.body or "",
		created_on = raw.created_at or "",
		inline = inline,
		inline_hunk = inline_hunk,
		state = comment_state,
		resolved_by = resolver and author(resolver) or nil,
		outdated = outdated,
		html_url = json.nilify(raw.html_url),
		_raw = inline and {
			review_id = json.nilify(raw.pull_request_review_id) or (review and json.nilify(review.id)) or nil,
		} or nil,
	}
end

---@param raw table
---@param review table|nil
---@return PullsActivityEntry|nil
function M.to_activity(raw, review)
	local event = tostring(raw.type or ""):lower()
	local actor = json.nilify(raw.user) and author(raw.user) or nil
	local date = raw.created_at or ""

	if event == "review" then
		local state_name = tostring((review or {}).state or ""):upper()
		if state_name == "PENDING" then
			return nil
		end
		local kind = state_name == "APPROVED" and "approval"
			or state_name == "REQUEST_CHANGES" and "changes_requested"
			or "review"
		local label = kind == "approval" and "approved"
			or kind == "changes_requested" and "requested changes"
			or "left a review"
		local body = raw.body ~= "" and raw.body or (review or {}).body or ""
		return { kind = kind, actor = actor, date = date, label = label, body = body ~= "" and body or nil }
	end

	if event == "pull_push" then
		local ok, decoded = pcall(vim.json.decode, tostring(json.nilify(raw.body) or ""))
		decoded = ok and json.safe_table(decoded) or {}
		local commits = json.safe_table(decoded.commit_ids)
		local count = #commits
		local force = decoded.is_force_push == true
		local label = force and "force pushed"
			or (count > 0 and string.format("pushed %d commit%s", count, count == 1 and "" or "s"))
			or "updated the source branch"
		return {
			kind = force and "force_pushed" or "update",
			actor = actor,
			date = date,
			label = label,
			_commit_ids = not force and commits or nil,
		}
	end

	local events = {
		close = { "closed", "closed" },
		reopen = { "reopened", "reopened" },
		merge_pull = { "merged", "merged" },
		delete_branch = { "update", "deleted the source branch" },
		lock = { "locked", "locked conversation" },
		unlock = { "unlocked", "unlocked conversation" },
		pin = { "pinned", "pinned" },
		unpin = { "unpinned", "unpinned" },
	}
	if events[event] then
		return { kind = events[event][1], actor = actor, date = date, label = events[event][2] }
	end

	if event == "label" then
		local label = json.nilify(raw.label) and raw.label.name or ""
		if label ~= "" then
			local added = tostring(json.nilify(raw.body) or "") == "1"
			return {
				kind = added and "labeled" or "unlabeled",
				actor = actor,
				date = date,
				label = (added and "added label: " or "removed label: ") .. label,
			}
		end
	end

	if event == "assignees" then
		local assignee = json.nilify(raw.assignee) and author(raw.assignee).username or ""
		local team = object_name(raw.assignee_team, "name")
		local removed = raw.removed_assignee == true
		local subject = assignee ~= "" and assignee or team
		return {
			kind = removed and "unassigned" or "assigned",
			actor = actor,
			date = date,
			label = (removed and "unassigned" or "assigned") .. (subject and (" " .. subject) or ""),
		}
	end

	if event == "review_request" then
		local reviewer = json.nilify(raw.assignee) and author(raw.assignee).username or ""
		local team = object_name(raw.assignee_team, "name")
		local subject = reviewer ~= "" and reviewer or team
		local removed = raw.removed_assignee == true
		return {
			kind = "review_requested",
			actor = actor,
			date = date,
			label = (removed and "removed review request" or "requested review")
				.. (subject and (" from " .. subject) or ""),
		}
	end

	if event == "dismiss_review" then
		return {
			kind = "review",
			actor = actor,
			date = date,
			label = "dismissed a review",
			body = nonempty(raw.body),
		}
	end

	if event == "milestone" then
		local before = object_name(raw.old_milestone, "title")
		local after = object_name(raw.milestone, "title")
		return {
			kind = after and "milestoned" or "demilestoned",
			actor = actor,
			date = date,
			label = after and (before and "changed milestone" or "added milestone") or "removed milestone",
			body = change(before, after),
		}
	end

	if event == "change_title" then
		return {
			kind = "renamed",
			actor = actor,
			date = date,
			label = "changed the title",
			body = change(nonempty(raw.old_title), nonempty(raw.new_title)),
		}
	end

	if event == "change_issue_ref" or event == "change_target_branch" then
		return {
			kind = "update",
			actor = actor,
			date = date,
			label = event == "change_issue_ref" and "changed issue reference" or "changed target branch",
			body = change(nonempty(raw.old_ref), nonempty(raw.new_ref)),
		}
	end

	local references = {
		issue_ref = "referenced",
		commit_ref = "referenced from a commit",
		comment_ref = "referenced from a comment",
		pull_ref = "referenced from a pull request",
	}
	if references[event] then
		return {
			kind = "referenced",
			actor = actor,
			date = date,
			label = references[event],
			body = object_name(raw.ref_issue, "title") or nonempty(raw.ref_commit_sha),
		}
	end

	if event == "add_dependency" or event == "remove_dependency" then
		return {
			kind = "update",
			actor = actor,
			date = date,
			label = event == "add_dependency" and "added dependency" or "removed dependency",
			body = object_name(raw.dependent_issue, "title") or nonempty(raw.body),
		}
	end

	return nil
end

return M
