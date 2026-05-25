local M = {}

local json = require("atlas.core.json")

---@param raw any
---@return PullsAuthor
local function normalize_author(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return { name = "Unknown", id = "", username = "unknown", nickname = "unknown" }
	end
	local username = json.safe_str(raw.username) or "unknown"
	local name = json.safe_str(raw.name) or username
	return {
		name = name,
		id = tostring(raw.id or ""),
		username = username,
		nickname = username,
	}
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

---@param raw_path string|nil
---@return string workspace, string repo, string repo_full_name
local function split_path(raw_path)
	local path = tostring(raw_path or "")
	if path == "" then
		return "", "", ""
	end
	local ws, name = path:match("^(.-)/([^/]+)$")
	if ws and name then
		return ws, name, path
	end
	return "", path, path
end

---@param raw table
---@return PullRequest|nil
function M.to_pull_request(raw)
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

	local workspace, repo, repo_full_name = split_path(project_path)

	local source_branch = json.safe_str(raw.source_branch) or ""
	local target_branch = json.safe_str(raw.target_branch) or ""
	local sha = json.nilify(raw.sha)

	---@type PullRequest
	return {
		id = iid,
		title = json.safe_str(raw.title) or "",
		description = json.safe_str(raw.description) or "",
		state = normalize_state(raw),
		author = normalize_author(raw.author),
		source = { branch = source_branch, commit_hash = "" },
		destination = { branch = target_branch, commit_hash = "" },
		comments_count = tonumber(raw.user_notes_count) or 0,
		tasks_count = 0,
		created_on = json.safe_str(raw.created_at) or "",
		updated_on = json.safe_str(raw.updated_at) or "",
		link = { html = json.safe_str(raw.web_url) or "" },
		provider = "gitlab",
		workspace = workspace,
		repo = repo,
		repo_full_name = repo_full_name,
		is_subscribed = type(raw.subscribed) == "boolean" and raw.subscribed or nil,
		_raw = {
			iid = iid,
			project_id = tonumber(raw.project_id),
			project_path = project_path,
			merge_status = json.safe_str(raw.merge_status),
			detailed_merge_status = json.safe_str(raw.detailed_merge_status),
			blocking_discussions_resolved = json.nilify(raw.blocking_discussions_resolved),
			has_conflicts = raw.has_conflicts == true,
			draft = raw.draft == true or raw.work_in_progress == true,
			labels = json.safe_table(raw.labels),
			assignees = json.safe_table(raw.assignees),
			reviewers = json.safe_table(raw.reviewers),
			milestone = json.nilify(raw.milestone),
			merged_at = json.safe_str(raw.merged_at),
			closed_at = json.safe_str(raw.closed_at),
			sha = type(sha) == "string" and sha or nil,
			pipeline = json.nilify(raw.head_pipeline) or json.nilify(raw.pipeline),
		},
	}
end

---@param raw_list table[]|nil
---@return PullsGroup[] groups grouped by repo_full_name
function M.to_pull_request_groups(raw_list)
	local by_repo = {}
	local order = {}
	for _, raw in ipairs(raw_list or {}) do
		local pr = M.to_pull_request(raw)
		if pr ~= nil then
			local key = pr.repo_full_name ~= "" and pr.repo_full_name or "unknown"
			if not by_repo[key] then
				by_repo[key] = {
					repo = {
						id = key,
						name = pr.repo,
						owner = pr.workspace,
						repo_name = pr.repo,
						html_url = nil,
					},
					prs = {},
				}
				table.insert(order, key)
			end
			table.insert(by_repo[key].prs, pr)
		end
	end

	local groups = {}
	for _, key in ipairs(order) do
		table.insert(groups, by_repo[key])
	end
	return groups
end

---@param raw table|nil
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
	return {
		name = json.safe_str(raw.name) or username,
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
	local username = tostring(user.username or "")
	if username == "" then
		return nil
	end
	return {
		name = tostring(user.name or username),
		id = tostring(user.id or ""),
		username = username,
		nickname = username,
	}
end

---@param body string
---@return "approval"|"changes_requested"|"update"
local function classify_system_note(body)
	local b = tostring(body or ""):lower()
	if b:find("unapproved this merge request", 1, true) then
		return "update"
	end
	if b:find("approved this merge request", 1, true) then
		return "approval"
	end
	if b:find("requested changes", 1, true) then
		return "changes_requested"
	end
	return "update"
end

local HUNK_WINDOW = 4

---@param user any
local function author_from(user)
	if type(user) ~= "table" then
		return nil
	end
	local username = tostring(user.username or "")
	if username == "" then
		return nil
	end
	return { name = tostring(user.name or username), nickname = username, id = tostring(user.id or "") }
end

---@param hunk DiffHunk
---@param side "old"|"new"
---@param line integer
---@return DiffHunk|nil
local function window_around(hunk, side, line)
	local lines = hunk.lines or {}
	local anchor_idx
	for i, l in ipairs(lines) do
		local target = side == "new" and l.new_line or l.old_line
		if target == line then
			anchor_idx = i
			break
		end
	end
	if not anchor_idx then
		return hunk
	end
	local first = math.max(1, anchor_idx - HUNK_WINDOW)
	local last = math.min(#lines, anchor_idx + HUNK_WINDOW)
	local windowed = {}
	for i = first, last do
		table.insert(windowed, lines[i])
	end
	return {
		header = hunk.header,
		context = hunk.context,
		old_start = hunk.old_start,
		old_count = hunk.old_count,
		new_start = hunk.new_start,
		new_count = hunk.new_count,
		lines = windowed,
	}
end

---@param file DiffFile|nil
---@param side "old"|"new"
---@param line integer
---@return DiffHunk|nil
local function find_hunk(file, side, line)
	if file == nil or type(file.hunks) ~= "table" then
		return nil
	end
	for _, h in ipairs(file.hunks) do
		local start_, count
		if side == "new" then
			start_, count = h.new_start or 0, h.new_count or 0
		else
			start_, count = h.old_start or 0, h.old_count or 0
		end
		if line >= start_ and line <= start_ + count - 1 then
			return window_around(h, side, line)
		end
	end
	return nil
end

---@param note table
---@param discussion_first_id any
---@param discussion_id string|nil
---@param resolved boolean|nil
---@param files_by_path table<string, DiffFile>
---@return PullsComment
function M.to_comment(note, discussion_first_id, discussion_id, resolved, files_by_path)
	local position = type(note.position) == "table" and note.position or nil
	local inline, inline_hunk
	if position and tostring(position.position_type or "text") == "text" then
		local new_line = tonumber(position.new_line)
		local old_line = tonumber(position.old_line)
		local side = new_line and "new" or "old"
		local line = new_line or old_line
		local path = tostring(position.new_path or position.old_path or "")
		if path ~= "" and line ~= nil then
			inline = {
				path = path,
				to = side == "new" and line or nil,
				from = side == "old" and line or nil,
			}
			inline_hunk = find_hunk(files_by_path[path], side, line)
		end
	end

	---@type "RESOLVED"|nil
	local state = nil
	if resolved == true then
		state = "RESOLVED"
	end

	local raw_with_discussion = note
	if type(discussion_id) == "string" and discussion_id ~= "" then
		raw_with_discussion = vim.tbl_extend("force", {}, note, { discussion_id = discussion_id })
	end

	return {
		id = note.id,
		parent_id = (note.id ~= discussion_first_id) and discussion_first_id or nil,
		author = author_from(note.author),
		content_raw = tostring(note.body or ""),
		created_on = tostring(note.created_at or ""),
		inline = inline,
		inline_hunk = inline_hunk,
		is_task = nil,
		state = state,
		_raw = raw_with_discussion,
	}
end

---@param gql_note table
---@param first_id integer|nil
---@param discussion_id string
---@return PullsComment
function M.to_comment_from_gql(gql_note, first_id, discussion_id)
	local note_id = tonumber(tostring(gql_note.id or ""):match("([^/]+)$") or "")
	local author = type(gql_note.author) == "table" and gql_note.author or {}
	local pos = type(gql_note.position) == "table" and gql_note.position or nil
	local inline = nil
	if pos and tostring(pos.positionType or "text") == "text" then
		local new_line = tonumber(pos.newLine)
		local old_line = tonumber(pos.oldLine)
		local side = new_line and "new" or "old"
		local line = new_line or old_line
		local p = tostring(pos.newPath or pos.oldPath or "")
		if p ~= "" and line ~= nil then
			inline = { path = p, to = side == "new" and line or nil, from = side == "old" and line or nil }
		end
	end
	local counts = {}
	for _, e in ipairs(((gql_note.awardEmoji or {}).nodes or {})) do
		local name = tostring(e.name or "")
		if name ~= "" then
			counts[name] = (counts[name] or 0) + 1
		end
	end
	return {
		id = note_id,
		parent_id = (note_id ~= first_id) and first_id or nil,
		author = type(author.username) == "string" and {
			name = tostring(author.name or author.username),
			nickname = author.username,
			id = "",
		} or nil,
		content_raw = tostring(gql_note.body or ""),
		created_on = tostring(gql_note.createdAt or ""),
		inline = inline,
		inline_hunk = nil,
		is_task = nil,
		state = gql_note.resolved == true and "RESOLVED" or nil,
		reactions = counts,
		_raw = { discussion_id = discussion_id },
	}
end

---@param note table
---@return PullsActivityEntry|nil
function M.to_activity(note)
	if note.system ~= true then
		return nil
	end
	local body = tostring(note.body or "")
	if body == "" then
		return nil
	end
	local first_line = body:match("([^\r\n]+)") or body
	local kind = classify_system_note(body)
	local content_raw = first_line
	if kind == "approval" or kind == "changes_requested" then
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
