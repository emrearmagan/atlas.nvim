local json = require("atlas.core.json")
local diff_parser = require("atlas.core.git.diff_parser")

local M = {}

---@param raw table|nil
---@return PullsAuthor
local function author(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return { id = "", name = "Unknown", username = "unknown", nickname = "unknown" }
	end
	local login = raw.login or "unknown"
	local name = raw.full_name or ""
	return {
		id = tostring(raw.id or ""),
		name = name ~= "" and name or login,
		username = login,
		nickname = login,
	}
end

---@param values table[]|nil
---@return PullsAuthor[]
local function authors(values)
	local result = {}
	for _, value in ipairs(json.safe_table(values)) do
		table.insert(result, author(value))
	end
	return result
end

---@param values table[]|nil
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
			decision = "pending",
		})
	end
	return result
end

---@param values table[]|nil
---@return table<string, integer>|nil
local function reaction_counts(values)
	local result = {}
	for _, value in ipairs(json.safe_table(values)) do
		local key = value.content
		if key and key ~= "" then
			result[key] = (result[key] or 0) + 1
		end
	end
	return next(result) and result or nil
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

---@param raw any
---@return { from: integer|nil, to: integer|nil, start_from: integer|nil, start_to: integer|nil }
function M.review_lines(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return {}
	end
	return {
		from = positive_line(raw.original_position),
		to = positive_line(raw.position),
	}
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
M.reaction_counts = reaction_counts
M.pull_state = state

---@param raw any
---@param fallback_slug string|nil
---@return PullRequest|nil
function M.to_pull_request(raw, fallback_slug)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local number = raw.number
	if number == nil then
		return nil
	end

	local base = json.nilify(raw.base) or {}
	local head = json.nilify(raw.head) or {}
	local repo_raw = json.nilify(base.repo) or {}
	local slug = repo_raw.full_name or fallback_slug or ""
	local workspace, repo = slug:match("^([^/]+)/([^/]+)$")

	local assignees = authors(raw.assignees)
	if #assignees == 0 and json.nilify(raw.assignee) then
		table.insert(assignees, author(raw.assignee))
	end
	local labels, label_ids = {}, {}
	for _, value in ipairs(json.safe_table(raw.labels)) do
		local name = value.name
		if name and name ~= "" then
			table.insert(labels, {
				name = name,
				color = (value.color or ""):gsub("^#", ""),
			})
		end
		if value.id then
			table.insert(label_ids, value.id)
		end
	end
	return {
		id = number,
		title = raw.title or "",
		description = raw.body or "",
		state = state(raw),
		author = author(raw.user),
		source = {
			branch = head.ref or "",
			commit_hash = head.sha or "",
			fetch_ref = string.format("refs/pull/%d/head", number),
		},
		destination = {
			branch = base.ref or "",
			commit_hash = base.sha or "",
		},
		comments_count = (raw.comments or 0) + (raw.review_comments or 0),
		tasks_count = 0,
		created_on = raw.created_at or "",
		updated_on = raw.updated_at or "",
		link = { html = raw.html_url or "" },
		provider = "gitea",
		workspace = workspace or "",
		repo = repo or slug,
		repo_full_name = slug,
		assignees = assignees,
		reviewers = reviewers(raw.requested_reviewers),
		labels = labels,
		lines_added = raw.additions,
		lines_removed = raw.deletions,
		_raw = {
			mergeable = raw.mergeable,
			merge_base = raw.merge_base,
			label_ids = label_ids,
		},
	}
end

---@param values table[]|nil
---@param fallback_slug string|nil
---@return PullsGroup[]|nil
function M.to_groups(values, fallback_slug)
	local prs = {}
	for _, raw in ipairs(values or {}) do
		local pr = M.to_pull_request(raw, fallback_slug)
		if not pr then
			return nil
		end
		table.insert(prs, pr)
	end
	if #prs == 0 then
		return {}
	end
	local first = prs[1]
	return {
		{
			repo = {
				id = first.repo_full_name,
				name = first.repo,
				owner = first.workspace,
				repo_name = first.repo,
				html_url = nil,
			},
			prs = prs,
		},
	}
end

---@param raw any
---@return PullRequest|nil
function M.to_search_pull_request(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local metadata = json.nilify(raw.pull_request)
	local repository = json.nilify(raw.repository)
	if type(metadata) ~= "table" or type(repository) ~= "table" then
		return nil
	end
	local slug = tostring(repository.full_name or "")
	if slug == "" and repository.owner and repository.name then
		slug = tostring(repository.owner) .. "/" .. tostring(repository.name)
	end
	if not slug:match("^[^/]+/[^/]+$") then
		return nil
	end

	local normalized = {}
	for key, value in pairs(raw) do
		normalized[key] = value
	end
	normalized.merged = metadata.merged
	normalized.draft = metadata.draft
	normalized.html_url = metadata.html_url or raw.html_url
	normalized.base = { repo = { full_name = slug } }
	normalized.head = {}
	return M.to_pull_request(normalized, slug)
end

---@param prs PullRequest[]|nil
---@return PullsGroup[]|nil
function M.group_pull_requests(prs)
	local groups, by_repo = {}, {}
	for _, pr in ipairs(prs or {}) do
		if type(pr) ~= "table" or tostring(pr.repo_full_name or "") == "" then
			return nil
		end
		local group = by_repo[pr.repo_full_name]
		if not group then
			group = {
				repo = {
					id = pr.repo_full_name,
					name = pr.repo,
					owner = pr.workspace,
					repo_name = pr.repo,
					html_url = nil,
				},
				prs = {},
			}
			by_repo[pr.repo_full_name] = group
			table.insert(groups, group)
		end
		table.insert(group.prs, pr)
	end
	return groups
end

---@param raw any
---@param review table|nil
---@param lines { from: integer|nil, to: integer|nil, start_from: integer|nil, start_to: integer|nil }|nil
---@return PullsComment|nil
function M.to_comment(raw, review, lines)
	raw = json.nilify(raw)
	if type(raw) ~= "table" or json.nilify(raw.id) == nil then
		return nil
	end
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
		author = author(raw.user),
		content_raw = raw.body or "",
		created_on = raw.created_at or "",
		inline = inline,
		inline_hunk = inline_hunk,
		state = comment_state,
		outdated = outdated,
		html_url = json.nilify(raw.html_url),
		_raw = inline and {
			review_id = json.nilify(raw.pull_request_review_id) or (review and json.nilify(review.id)) or nil,
		} or nil,
	}
end

---@param comments PullsComment[]
---@return PullsComment[]
function M.thread_comments(comments)
	table.sort(comments, function(left, right)
		local left_date = tostring(left.created_on or "")
		local right_date = tostring(right.created_on or "")
		if left_date ~= right_date then
			return left_date < right_date
		end
		local left_id = tonumber(left.id)
		local right_id = tonumber(right.id)
		if left_id and right_id and left_id ~= right_id then
			return left_id < right_id
		end
		return tostring(left.id or "") < tostring(right.id or "")
	end)

	local roots = {}
	for _, comment in ipairs(comments) do
		local inline = comment.inline
		local path = type(inline) == "table" and tostring(inline.path or "") or ""
		local line = type(inline) == "table" and (inline.to or inline.from) or nil
		local side = type(inline) == "table" and inline.to and "new" or "old"
		local raw = type(comment._raw) == "table" and comment._raw or {}
		local review_id = tostring(raw.review_id or "")
		if review_id ~= "" and path ~= "" and type(line) == "number" then
			local key = table.concat({ review_id, path, side, tostring(line) }, "\0")
			local root = roots[key]
			if root then
				comment.parent_id = root.id
			else
				comment.parent_id = nil
				roots[key] = comment
			end
		end
	end
	return comments
end

---@param raw any
---@param review table|nil
---@return PullsActivityEntry|nil
function M.to_activity(raw, review)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
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
		local body = raw.body or ""
		local decoded
		if body ~= "" then
			local ok, value = pcall(vim.json.decode, body)
			decoded = ok and value or nil
		end
		local commits = type(decoded) == "table" and decoded.commit_ids or nil
		local count = type(commits) == "table" and #commits or 0
		local force = type(decoded) == "table" and decoded.is_force_push == true
		local label = force and "force pushed" or string.format("pushed %d commit%s", count, count == 1 and "" or "s")
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
