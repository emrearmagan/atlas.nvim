local M = {}

local json = require("atlas.core.json")

---@param raw any
---@return PullsAuthor
local function normalize_author(raw)
	raw = json.nilify(raw)
	if type(raw) == "table" then
		local username = json.safe_str(raw.username) or "unknown"
		local name = json.safe_str(raw.name) or ""
		return {
			name = name ~= "" and name or username,
			id = tostring(raw.id or ""),
			username = username,
			nickname = username,
		}
	end
	return { name = "Unknown", id = "", username = "unknown", nickname = "unknown" }
end

---@param values table
---@return PullsAuthor[]
local function normalize_authors(values)
	local authors = {}
	for _, raw in ipairs(values) do
		if type(raw) == "table" then
			table.insert(authors, normalize_author(raw))
		end
	end
	return authors
end

---@param values table
---@return PullsReviewer[]
local function normalize_reviewers(values)
	local reviewers = {}
	for _, raw in ipairs(values) do
		if type(raw) == "table" then
			local author = normalize_author(raw)
			table.insert(reviewers, {
				id = author.id,
				provider_id = author.id,
				name = author.name,
				username = author.username,
				nickname = author.nickname,
				decision = "pending",
				role = "reviewer",
			})
		end
	end
	return reviewers
end

---@param values any
---@return PullsReviewer[]|nil
local function normalize_optional_reviewers(values)
	if json.nilify(values) == nil then
		return nil
	end
	return normalize_reviewers(json.safe_table(values))
end

---@param values table
---@return PullsLabel[]
local function normalize_labels(values)
	local labels = {}
	for _, raw in ipairs(values) do
		local name = type(raw) == "table" and json.safe_str(raw.name) or json.safe_str(raw)
		if name and name ~= "" then
			table.insert(labels, {
				name = name,
				color = type(raw) == "table" and json.safe_str(raw.color) or nil,
			})
		end
	end
	return labels
end

---@param mr table
---@return "open"|"merged"|"declined"|"draft"
local function normalize_state(mr)
	if mr.draft == true or mr.work_in_progress == true then
		return "draft"
	end
	local s = tostring(mr.state or ""):lower()
	if s == "merged" then
		return "merged"
	end
	if s == "closed" then
		return "declined"
	end
	return "open"
end

---@param raw any Decoded API value.
---@return GitLabPullRequest|nil
local function map_summary(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local iid = tonumber(raw.iid)
	if iid == nil then
		return nil
	end

	-- references.full looks like "group/proj!7"
	local refs = json.nilify(raw.references)
	local full_ref = type(refs) == "table" and json.safe_str(refs.full) or nil
	local project_path = ""
	if full_ref then
		project_path = full_ref:match("^(.-)!%d+$") or ""
	end
	if project_path == "" then
		local web = json.safe_str(raw.web_url) or ""
		project_path = web:match("^https?://[^/]+/(.+)/%-/merge_requests/") or ""
	end

	local workspace, repo = project_path:match("^(.*)/([^/]+)$")
	workspace = workspace or ""
	repo = repo or project_path

	local source_branch = json.safe_str(raw.source_branch) or ""
	local target_branch = json.safe_str(raw.target_branch) or ""
	local sha = json.nilify(raw.sha)
	local diff_refs = json.nilify(raw.diff_refs)
	local head_sha = type(diff_refs) == "table" and json.safe_str(diff_refs.head_sha) or nil
	local base_sha = type(diff_refs) == "table" and json.safe_str(diff_refs.base_sha) or nil

	---@type GitLabPullRequest
	return {
		id = iid,
		title = json.safe_str(raw.title) or "",
		state = normalize_state(raw),
		author = normalize_author(raw.author),
		source = {
			branch = source_branch,
			commit_hash = head_sha or (type(sha) == "string" and sha or ""),
			fetch_ref = string.format("refs/merge-requests/%d/head", iid),
		},
		destination = { branch = target_branch, commit_hash = base_sha or "" },
		comments_count = tonumber(raw.user_notes_count) or 0,
		created_on = json.safe_str(raw.created_at) or "",
		updated_on = json.safe_str(raw.updated_at) or "",
		link = { html = json.safe_str(raw.web_url) or "" },
		provider = "gitlab",
		workspace = workspace,
		repo = repo,
		repo_full_name = project_path,
		reviewers = normalize_optional_reviewers(raw.reviewers),
		merge_status = json.safe_str(raw.merge_status),
		detailed_merge_status = json.safe_str(raw.detailed_merge_status),
		blocking_discussions_resolved = json.nilify(raw.blocking_discussions_resolved),
		has_conflicts = raw.has_conflicts == true,
		diff_refs = diff_refs,
	}
end

---@param raw any Decoded API value.
---@return GitLabPullRequest|nil
function M.to_pull_request(raw)
	return map_summary(raw)
end

---@param raw any Decoded API value.
---@return GitLabPullRequestDetails|nil
function M.to_pull_request_details(raw)
	local pr = map_summary(raw)
	if pr == nil then
		return nil
	end
	---@cast pr GitLabPullRequestDetails
	local value = json.nilify(raw)
	pr.description = json.safe_str(value.description) or ""
	pr.is_subscribed = json.nilify(value.subscribed)
	pr.assignees = normalize_authors(json.safe_table(value.assignees))
	pr.reviewers = normalize_reviewers(json.safe_table(value.reviewers))
	pr.labels = normalize_labels(json.safe_table(value.labels))
	return pr
end

---@param raw_list table[]
---@return PullRequest[]
function M.to_pull_requests(raw_list)
	local pulls = {}
	for _, raw in ipairs(raw_list) do
		local pr = M.to_pull_request(raw)
		if pr then
			table.insert(pulls, pr)
		end
	end
	return pulls
end

---@param raw any Decoded API value.
---@return PullsUser|nil
function M.to_user(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local username = json.safe_str(raw.username) or ""
	if username == "" then
		return nil
	end
	local name = json.safe_str(raw.name) or ""
	return {
		name = name ~= "" and name or username,
		id = tostring(raw.id or ""),
		username = username,
	}
end

---@param user any
---@return PullsAuthor|nil
local function actor_from(user)
	if type(user) ~= "table" then
		return nil
	end
	local username = json.safe_str(user.username) or ""
	if username == "" then
		return nil
	end
	local name = json.safe_str(user.name) or ""
	return {
		name = name ~= "" and name or username,
		id = tostring(user.id or ""),
		username = username,
		nickname = username,
	}
end

---@param body string
---@return "approval"|"unapproval"|"changes_requested"|"update"
local function classify_system_note(body)
	local b = tostring(body or ""):lower()
	if b:find("unapproved this merge request", 1, true) then
		return "unapproval"
	end
	if b:find("approved this merge request", 1, true) then
		return "approval"
	end
	if b:find("requested changes", 1, true) then
		return "changes_requested"
	end
	return "update"
end

---@param position table
---@return PullsInlineCommentPosition|nil
local function to_inline_position(position)
	local path = json.safe_str(position.new_path) or json.safe_str(position.old_path) or ""
	local old_line = tonumber(position.old_line)
	local new_line = tonumber(position.new_line)
	local line_range = type(position.line_range) == "table" and position.line_range or {}
	local start = type(line_range.start) == "table" and line_range.start or {}
	if path == "" or (old_line == nil and new_line == nil) then
		return nil
	end
	return {
		path = path,
		old_path = json.safe_str(position.old_path),
		from = old_line,
		to = new_line,
		start_from = tonumber(start.old_line),
		start_to = tonumber(start.new_line),
		commit_hash = json.safe_str(position.head_sha),
	}
end

---@param values table|nil
---@return table<string, integer>|nil
local function reaction_counts(values)
	local counts
	for _, reaction in ipairs(type(values) == "table" and values or {}) do
		local name = type(reaction) == "table" and json.safe_str(reaction.name) or nil
		if name and name ~= "" then
			counts = counts or {}
			counts[name] = (counts[name] or 0) + 1
		end
	end
	return counts
end

---@param note table
---@param discussion_first_id any
---@param discussion_id string|nil
---@param resolved boolean|nil
---@return PullsComment
function M.to_comment(note, discussion_first_id, discussion_id, resolved)
	local position = type(note.position) == "table" and note.position or nil
	local original_position = type(note.original_position) == "table" and note.original_position or nil
	local outdated = position == nil and original_position ~= nil
	position = position or original_position
	local diff_refs = position
			and {
				base_sha = json.safe_str(position.base_sha),
				start_sha = json.safe_str(position.start_sha),
				head_sha = json.safe_str(position.head_sha),
			}
		or nil
	local file, inline
	local position_type = position and tostring(position.position_type or "text") or ""
	if position_type == "text" then
		inline = to_inline_position(position)
	elseif position_type == "file" then
		local path = json.safe_str(position.new_path) or json.safe_str(position.old_path)
		if path then
			file = {
				path = path,
				old_path = json.safe_str(position.old_path),
				commit_hash = json.safe_str(position.head_sha),
			}
		end
	end
	local state = resolved and "RESOLVED" or (outdated and "OUTDATED" or nil)
	local is_thread_root = note.id == discussion_first_id

	return {
		id = note.id,
		parent_id = not is_thread_root and discussion_first_id or nil,
		thread_id = discussion_id ~= nil and discussion_id ~= "" and discussion_id or nil,
		author = actor_from(note.author),
		content_raw = tostring(note.body or ""),
		created_on = tostring(note.created_at or ""),
		resolved_on = resolved and is_thread_root and json.safe_str(note.resolved_at) or nil,
		resolved_by = resolved and is_thread_root and actor_from(note.resolved_by) or nil,
		file = file,
		inline = inline,
		is_task = nil,
		state = state,
		outdated = outdated,
		reactions = reaction_counts(note.award_emoji),
		html_url = json.safe_str(note.web_url),
		_raw = diff_refs and { diff_refs = diff_refs } or nil,
	}
end

---@param draft table
---@param discussion_first_id number|string|nil
---@return PullsComment
function M.to_draft_comment(draft, discussion_first_id)
	local discussion_id = type(draft.discussion_id) == "string" and draft.discussion_id or ""
	local note = vim.tbl_extend("force", {}, draft, {
		id = "draft:" .. tostring(draft.id or ""),
		body = tostring(draft.note or ""),
	})
	local comment = M.to_comment(note, discussion_first_id, discussion_id, false)
	if draft.author_id ~= nil and draft.author_id ~= vim.NIL then
		comment.author = { name = "You", nickname = nil, username = "", id = tostring(draft.author_id) }
	end
	comment.state = "PENDING"
	comment._raw = vim.tbl_extend("force", comment._raw or {}, { draft_note_id = draft.id })
	return comment
end

---@param note table
---@return PullsActivityEntry|nil
function M.to_inline_thread_activity(note)
	if note.system == true then
		return nil
	end
	local position = type(note.position) == "table" and note.position or nil
	if not position or tostring(position.position_type or "text") ~= "text" then
		return nil
	end
	local inline = to_inline_position(position)
	local line = inline and (inline.to or inline.from)
	if not inline or not line then
		return nil
	end
	return {
		kind = "comment",
		actor = actor_from(note.author),
		date = tostring(note.created_at or ""),
		label = string.format("started a review thread on %s:%d", inline.path, line),
		_raw = { gitlab_inline_thread_activity = true },
	}
end

---@param note table
---@return PullsActivityEntry|nil
function M.to_activity(note)
	if note.system ~= true then
		return M.to_inline_thread_activity(note)
	end
	local body = tostring(note.body or "")
	if body == "" then
		return nil
	end
	local first_line = body:match("([^\r\n]+)") or body
	local kind = classify_system_note(body)
	local content_raw = first_line
	if kind == "unapproval" then
		content_raw = "unapproved"
	elseif kind == "approval" or kind == "changes_requested" then
		content_raw = nil
	end
	return {
		kind = kind,
		actor = actor_from(note.author),
		date = tostring(note.created_at or ""),
		label = content_raw,
	}
end

return M
