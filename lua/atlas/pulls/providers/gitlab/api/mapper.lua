local M = {}

local gitlab_mapper = require("atlas.providers.gitlab.mapper")
local json = require("atlas.core.json")

---@param raw any
---@return AtlasUser
local function normalize_author(raw)
	raw = json.nilify(raw)
	if type(raw) == "table" then
		local username = json.safe_str(raw.username) or "unknown"
		local name = json.safe_str(raw.name) or ""
		local id = tostring(raw.id or "")
		return {
			name = name ~= "" and name or username,
			id = id:match("([^/]+)$") or id,
			username = username,
		}
	end
	return { name = "Unknown", id = "", username = "unknown" }
end

---@param values table
---@return AtlasUser[]
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
				text_color = type(raw) == "table" and json.safe_str(raw.text_color) or nil,
			})
		end
	end
	return labels
end

---@param mr table
---@return "open"|"merged"|"declined"|"draft"
local function normalize_state(mr)
	local s = tostring(mr.state or ""):lower()
	if s == "merged" then
		return "merged"
	end
	if s == "closed" then
		return "declined"
	end
	if mr.draft == true or mr.work_in_progress == true then
		return "draft"
	end
	return "open"
end

---@param raw any Decoded API value.
---@return GitLabPullRequest|nil
function M.to_pull_request(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local iid = tonumber(raw.iid)
	if iid == nil then
		return nil
	end

	-- REST references.full and GraphQL reference look like "group/proj!7".
	local refs = json.nilify(raw.references)
	local full_ref = json.safe_str(raw.reference) or (type(refs) == "table" and json.safe_str(refs.full) or nil)
	local web_url = json.safe_str(raw.web_url) or ""
	local project_path = ""
	if full_ref then
		project_path = full_ref:match("^(.-)!%d+$") or ""
	end
	if project_path == "" then
		project_path = web_url:match("^https?://[^/]+/(.+)/%-/merge_requests/") or ""
	end

	local owner, name = project_path:match("^(.*)/([^/]+)$")
	owner = owner or ""
	name = name or project_path

	local source_branch = json.safe_str(raw.source_branch) or ""
	local target_branch = json.safe_str(raw.target_branch) or ""
	local sha = json.nilify(raw.sha)
	local diff_refs = json.nilify(raw.diff_refs)
	local head_sha = type(diff_refs) == "table" and json.safe_str(diff_refs.head_sha) or nil
	local base_sha = type(diff_refs) == "table" and json.safe_str(diff_refs.base_sha) or nil

	---@type GitLabPullRequest
	return {
		id = iid,
		node_id = json.safe_str(raw.node_id),
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
		link = { html = web_url },
		provider = "gitlab",
		repo = {
			id = project_path,
			name = name,
			owner = owner,
			repo_name = name,
			full_name = project_path,
			html_url = web_url:match("^(.-)/%-/merge_requests/%d+") or "",
		},
		repo_full_name = project_path,
		reviewers = normalize_optional_reviewers(json.safe_table(raw.reviewers).nodes or raw.reviewers),
		merge_status = json.safe_str(raw.merge_status),
		detailed_merge_status = json.safe_str(raw.detailed_merge_status),
		diff_refs = diff_refs,
	}
end

---@param raw any Decoded API value.
---@param viewer string|nil Username of the current user
---@return GitLabPullRequestDetails|nil
function M.to_pull_request_details(raw, viewer)
	local value = json.nilify(raw)
	if type(value) ~= "table" then
		return nil
	end
	---@type GitLabPullRequestDetails
	return {
		description = json.safe_str(value.description) or "",
		reactions = gitlab_mapper.award_reactions(json.safe_table(value.awardEmoji).nodes, viewer),
		is_subscribed = json.nilify(value.subscribed),
		assignees = normalize_authors(json.safe_table(json.safe_table(value.assignees).nodes or value.assignees)),
		labels = normalize_labels(json.safe_table(json.safe_table(value.labels).nodes or value.labels)),
	}
end

---@param raw_list table[]
---@return PullRequest[]
function M.to_pull_requests(raw_list)
	local pulls = {}
	for _, raw in ipairs(json.safe_table(raw_list)) do
		local pr = M.to_pull_request(raw)
		if pr then
			table.insert(pulls, pr)
		end
	end
	return pulls
end

---@param user any
---@return AtlasUser|nil
local function actor_from(user)
	if type(user) ~= "table" then
		return nil
	end
	local username = json.safe_str(user.username) or ""
	if username == "" then
		return nil
	end
	local name = json.safe_str(user.name) or ""
	local id = tostring(user.id or "")
	return {
		name = name ~= "" and name or username,
		id = id:match("([^/]+)$") or id,
		username = username,
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

---@param position table|nil REST position
---@return PullsFileCommentPosition|nil file, PullsInlineCommentPosition|nil inline
local function to_rest_position(position)
	if not position then
		return nil, nil
	end
	local position_type = tostring(position.position_type or "text")
	if position_type == "text" then
		return nil, to_inline_position(position)
	end
	local path = json.safe_str(position.new_path) or json.safe_str(position.old_path)
	if position_type ~= "file" or not path then
		return nil, nil
	end
	return {
		path = path,
		old_path = json.safe_str(position.old_path),
		commit_hash = json.safe_str(position.head_sha),
	},
		nil
end

---@param position table|nil GraphQL `DiffPosition`
---@return PullsFileCommentPosition|nil file, PullsInlineCommentPosition|nil inline
local function to_graphql_position(position)
	if not position then
		return nil, nil
	end
	local path = json.safe_str(position.newPath) or json.safe_str(position.oldPath)
	local commit_hash = json.safe_str(json.safe_table(position.diffRefs).headSha)
	if not path then
		return nil, nil
	end
	if position.positionType == "file" then
		return { path = path, old_path = json.safe_str(position.oldPath), commit_hash = commit_hash }, nil
	end
	local old_line, new_line = tonumber(position.oldLine), tonumber(position.newLine)
	if position.positionType ~= "text" or (old_line == nil and new_line == nil) then
		return nil, nil
	end
	return nil,
		{
			path = path,
			old_path = json.safe_str(position.oldPath),
			from = old_line,
			to = new_line,
			commit_hash = commit_hash,
		}
end

---@param note table GraphQL `Note`
---@param viewer string|nil Username of the current user
---@param author_username string|nil
---@return PullsComment
function M.to_comment(note, viewer, author_username)
	local discussion = json.safe_table(note.discussion)
	local root = json.safe_table(json.safe_table(json.safe_table(discussion.notes).nodes)[1])
	local id = gitlab_mapper.note_id(note.id)
	local root_id = gitlab_mapper.note_id(root.id)
	local is_root = root_id == nil or root_id == id
	local resolved = discussion.resolved == true
	local file, inline = to_graphql_position(json.nilify(note.position))
	return {
		id = id,
		parent_id = not is_root and root_id or nil,
		thread_id = json.safe_str(discussion.id),
		author = actor_from(note.author),
		author_roles = gitlab_mapper.author_roles(note, author_username),
		body = tostring(note.body or ""),
		created_at = json.safe_str(note.createdAt) or "",
		resolved_at = resolved and is_root and json.safe_str(discussion.resolvedAt) or nil,
		resolved_by = resolved and is_root and actor_from(discussion.resolvedBy) or nil,
		file = file,
		inline = inline,
		state = resolved and "RESOLVED" or nil,
		reactions = gitlab_mapper.award_reactions(json.safe_table(note.awardEmoji).nodes, viewer),
		url = json.safe_str(note.url),
	}
end

---@param raw table GraphQL `MergeRequest`
---@param viewer string|nil Username of the current user
---@param author_username string|nil
---@return PullsComment|nil
function M.to_description(raw, viewer, author_username)
	local id = json.safe_str(raw.id)
	if not id then
		return nil
	end
	return {
		id = id,
		author = actor_from(raw.author),
		author_roles = gitlab_mapper.author_roles(raw, author_username),
		body = tostring(raw.description or ""),
		created_at = json.safe_str(raw.createdAt) or "",
		reactions = gitlab_mapper.award_reactions(json.safe_table(raw.awardEmoji).nodes, viewer),
		url = json.safe_str(raw.webUrl),
	}
end

---@param note table REST note of a discussion
---@param discussion table REST discussion
---@param mr_url string
---@param author_username string|nil
---@return PullsComment
function M.to_discussion_note(note, discussion, mr_url, author_username)
	local root = json.safe_table(json.safe_table(discussion.notes)[1])
	local is_root = root.id == note.id
	local resolved = root.resolved == true
	local position = json.nilify(note.position)
	local original_position = json.nilify(note.original_position)
	local outdated = position == nil and original_position ~= nil
	local file, inline = to_rest_position(position or original_position)
	return {
		id = gitlab_mapper.note_id(note.id),
		parent_id = not is_root and gitlab_mapper.note_id(root.id) or nil,
		thread_id = "gid://gitlab/Discussion/" .. tostring(discussion.id),
		author = actor_from(note.author),
		author_roles = gitlab_mapper.author_roles(note, author_username),
		body = tostring(note.body or ""),
		created_at = tostring(note.created_at or ""),
		resolved_at = resolved and is_root and json.safe_str(note.resolved_at) or nil,
		resolved_by = resolved and is_root and actor_from(note.resolved_by) or nil,
		file = file,
		inline = inline,
		state = resolved and "RESOLVED" or (outdated and "OUTDATED" or nil),
		outdated = outdated,
		url = string.format("%s#note_%s", mr_url, tostring(note.id)),
	}
end

---@param draft table REST draft note
---@return PullsComment
function M.to_draft_comment(draft)
	local file, inline = to_rest_position(json.nilify(draft.position))
	local discussion_id = json.safe_str(draft.discussion_id)
	local author_id = json.nilify(draft.author_id)
	return {
		id = tostring(draft.id),
		thread_id = discussion_id and ("gid://gitlab/Discussion/" .. discussion_id) or nil,
		author = author_id and { name = "You", username = "", id = tostring(author_id) } or nil,
		body = tostring(draft.note or ""),
		created_at = tostring(draft.created_at or ""),
		file = file,
		inline = inline,
		pending = true,
	}
end

---@param values table|nil
---@return DiffHunkLines|nil
function M.to_diff_hunk(values)
	local lines = json.safe_table(values)
	if #lines == 0 then
		return nil
	end
	local hunk = {
		header = "",
		context = "",
		old_start = 0,
		old_count = 0,
		new_start = 0,
		new_count = 0,
		additions = 0,
		deletions = 0,
		lines = {},
	}
	local kinds = { new = "add", old = "remove", [""] = "context" }
	for _, line in ipairs(lines) do
		local kind = kinds[json.safe_str(line.type) or ""] or "meta"
		local text = (json.safe_str(line.text) or ""):gsub("\r?\n$", "")
		local old_line = tonumber(line.oldLine)
		local new_line = tonumber(line.newLine)
		table.insert(hunk.lines, {
			kind = kind,
			text = text,
			content = kind == "meta" and text or text:sub(2),
			old_line = old_line,
			new_line = new_line,
		})
		if old_line then
			hunk.old_start = hunk.old_start == 0 and old_line or hunk.old_start
			hunk.old_count = hunk.old_count + 1
		end
		if new_line then
			hunk.new_start = hunk.new_start == 0 and new_line or hunk.new_start
			hunk.new_count = hunk.new_count + 1
		end
		hunk.additions = hunk.additions + (kind == "add" and 1 or 0)
		hunk.deletions = hunk.deletions + (kind == "remove" and 1 or 0)
	end
	return hunk
end

---@param note table
---@return GitLabPullsActivityEntry|nil
local function to_inline_thread_activity(note)
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
		inline_thread = true,
	}
end

---@param note table
---@return PullsActivityEntry|nil
function M.to_activity(note)
	if note.system ~= true then
		return to_inline_thread_activity(note)
	end
	local body = tostring(note.body or "")
	if body == "" then
		return nil
	end
	local first_line = body:match("([^\r\n]+)") or body
	local kind = classify_system_note(body)
	local label = first_line
	if kind == "unapproval" then
		label = "unapproved"
	elseif kind == "approval" or kind == "changes_requested" then
		label = nil
	end
	return {
		kind = kind,
		actor = actor_from(note.author),
		date = tostring(note.created_at or ""),
		label = label,
	}
end

return M
