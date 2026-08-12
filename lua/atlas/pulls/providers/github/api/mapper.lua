local M = {}

local json = require("atlas.core.json")
local diff_parser = require("atlas.core.git.diff_parser")
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

---@param raw table
---@return PullsReviewer[]|nil
local function pull_reviewers(raw)
	if json.nilify(raw.latestOpinionatedReviews) == nil then
		return nil
	end

	local reviewers = {}
	for _, node in ipairs(github_mapping.connection_nodes(raw.latestOpinionatedReviews)) do
		local author = pull_author(node.author)
		if author.username ~= "" then
			local state = tostring(node.state or ""):upper()
			local decision = state == "APPROVED" and "approved"
				or state == "CHANGES_REQUESTED" and "changes_requested"
				or "pending"
			table.insert(reviewers, {
				id = author.id ~= "" and author.id or author.username,
				provider_id = author.username,
				name = author.name,
				username = author.username,
				nickname = author.nickname,
				decision = decision,
			})
		end
	end
	return reviewers
end

---@param diff_hunk string|nil
---@return DiffHunk|nil
local function parse_diff_hunk(diff_hunk)
	if type(diff_hunk) ~= "string" or diff_hunk == "" then
		return nil
	end
	-- The shared parser expects a complete diff header, so wrap GitHub's hunk-only snippet.
	local synthetic = "diff --git a/x b/x\n--- a/x\n+++ b/x\n" .. diff_hunk .. "\n"
	local files = diff_parser.parse(synthetic) ---@type DiffFile[]
	if #files == 0 or #files[1].hunks == 0 then
		return nil
	end

	return files[1].hunks[1]
end

---@param raw table
---@return PullRequest
function M.to_pull_request(raw)
	local number = tostring(raw.number or "")
	local author = pull_author(raw.author)

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
		reviewers = pull_reviewers(raw),
		labels = pull_labels(raw),
		lines_added = tonumber(raw.additions),
		lines_removed = tonumber(raw.deletions),
		_raw = {
			node_id = json.safe_str(raw.id),
			commits = json.nilify(raw.commits),
		},
	}
end

---@param prs PullRequest[]
---@return PullsGroup[]
function M.to_pull_request_groups(prs)
	local by_repo = {}
	local groups = {}
	for _, pr in ipairs(prs or {}) do
		local key = pr.repo_full_name or ""
		local group = by_repo[key]
		if not group then
			group = {
				repo = { id = key, name = key, owner = pr.workspace, repo_name = pr.repo },
				prs = {},
			}
			by_repo[key] = group
			table.insert(groups, group)
		end
		table.insert(group.prs, pr)
	end
	return groups
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
---@param thread_state {pending: boolean|nil, resolved: boolean, outdated: boolean}|nil
---@return PullsComment
function M.to_comment(raw, thread_state)
	local line = json.nilify(raw.line)
	local original_line = json.nilify(raw.original_line)
	local path = json.nilify(raw.path)
	local subject_type = tostring(raw.subject_type or ""):upper()

	local file, inline, inline_hunk, inline_hunk_anchor
	if path ~= nil then
		local side = raw.side == "LEFT" and "old" or "new"
		local anchor = line or original_line
		if subject_type == "FILE" then
			file = { path = tostring(path) }
		elseif anchor then
			inline_hunk_anchor = original_line or anchor
			inline = {
				path = tostring(path),
				from = side == "old" and anchor or nil,
				to = side == "new" and anchor or nil,
			}
		end
		inline_hunk = parse_diff_hunk(raw.diff_hunk)
		if inline and inline_hunk and inline_hunk_anchor then
			inline_hunk = diff_parser.window_hunk(inline_hunk, side, inline_hunk_anchor)
		end
	end

	local result = comment(raw, type(raw.user) == "table" and raw.user or nil)
	result.parent_id = json.nilify(raw.in_reply_to_id)
	result.file = file
	result.inline = inline
	result.inline_hunk = inline_hunk
	result.inline_hunk_anchor = inline_hunk and inline_hunk_anchor or nil
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
	local result = M.to_comment({
		id = node.databaseId,
		in_reply_to_id = reply_to and reply_to.databaseId or nil,
		user = { login = author.login, id = author.databaseId },
		body = node.body,
		path = thread.path or node.path,
		subject_type = thread.subjectType or node.subjectType,
		diff_hunk = node.diffHunk,
		line = thread.line or node.line,
		original_line = thread.originalLine or node.originalLine,
		side = thread.diffSide,
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
	result._raw = { comment_id = tostring(node.id or "") }
	if result.parent_id == nil then
		result.parent_id = fallback_parent
	end
	return result
end

---@param comment PullsComment
---@return table
function M.review_thread(comment)
	local inline = comment.inline or {}
	local file = comment.file
	return {
		id = tostring(comment.thread_id or ""),
		subjectType = file and "FILE" or "LINE",
		path = file and file.path or inline.path,
		line = inline.to,
		originalLine = comment.inline_hunk_anchor or inline.from,
		diffSide = not file and (inline.from ~= nil and "LEFT" or "RIGHT") or nil,
		isResolved = comment.state == "RESOLVED",
		isOutdated = comment.outdated == true or comment.state == "OUTDATED",
	}
end

---@param comments PullsComment[]
function M.normalize_inline_hunks(comments)
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
