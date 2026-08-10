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
		_raw = raw,
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

	local inline, inline_hunk, inline_hunk_anchor
	if path ~= nil then
		local side = raw.side == "LEFT" and "old" or "new"
		local anchor = line or original_line
		inline_hunk_anchor = original_line or anchor
		if anchor then
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

return M
