local M = {}

local service = require("atlas.pulls.providers.gitlab.api.service")
local diff_parser = require("atlas.core.git.diff_parser")

local HUNK_WINDOW = 4

---@param pr PullRequest
---@return string project_path, integer|nil iid
local function project_iid(pr)
	local raw = type(pr._raw) == "table" and pr._raw or {}
	local path = tostring(raw.project_path or pr.repo_full_name or "")
	local iid = tonumber(raw.iid or pr.id)
	return path, iid
end

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

---@param files DiffFile[]
---@return table<string, DiffFile>
local function index_files(files)
	local by_path = {}
	for _, f in ipairs(files or {}) do
		if type(f.path) == "string" and f.path ~= "" then
			by_path[f.path] = f
		end
		if type(f.old_path) == "string" and f.old_path ~= "" and by_path[f.old_path] == nil then
			by_path[f.old_path] = f
		end
	end
	return by_path
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

---@param change table
---@return string
local function rebuild_unified_diff(change)
	local new_path = tostring(change.new_path or "")
	local old_path = tostring(change.old_path or new_path)
	local body = tostring(change.diff or "")
	local header = string.format("diff --git a/%s b/%s\n", old_path, new_path)
	if not body:find("^%-%-%- ") then
		header = header .. string.format("--- a/%s\n+++ b/%s\n", old_path, new_path)
	end
	return header .. body
end

---@param note table
---@param discussion_first_id any
---@param discussion_id string|nil
---@param resolved boolean|nil
---@param files_by_path table<string, DiffFile>
---@return PullsComment
local function normalize_note(note, discussion_first_id, discussion_id, resolved, files_by_path)
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

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_general_comments(pr, opts, on_done)
	opts = opts or {}
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		vim.schedule(function()
			on_done(nil, "Invalid MR identifier")
		end)
		return nil
	end

	local cache_key = string.format("gitlab_pulls:general_comments:%s!%d", path, iid)
	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint =
		string.format("/projects/%s/merge_requests/%d/discussions?per_page=100", service.url_encode(path), iid)
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local comments = {}
		for _, discussion in ipairs(type(result) == "table" and result or {}) do
			local notes = type(discussion.notes) == "table" and discussion.notes or {}
			if #notes > 0 then
				local first = notes[1]
				if first.system ~= true and type(first.position) ~= "table" then
					local resolved = first.resolved == true
					local discussion_id = tostring(discussion.id or "")
					for _, note in ipairs(notes) do
						if note.system ~= true then
							table.insert(comments, normalize_note(note, first.id, discussion_id, resolved, {}))
						end
					end
				end
			end
		end
		service.set_memory_cache(cache_key, comments)
		on_done(comments, nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(pr, opts, on_done)
	opts = opts or {}
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		vim.schedule(function()
			on_done(nil, "Invalid MR identifier")
		end)
		return nil
	end

	local cache_key = string.format("gitlab_pulls:comments:%s!%d", path, iid)
	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local encoded = service.url_encode(path)
	local discussions_ep = string.format("/projects/%s/merge_requests/%d/discussions?per_page=100", encoded, iid)
	local changes_ep = string.format("/projects/%s/merge_requests/%d/changes", encoded, iid)

	local pending = 2
	local discussions_result, changes_result
	local first_err
	local handles = {}
	local cancelled = false

	local function finalize()
		if cancelled then
			return
		end
		if discussions_result == nil then
			on_done(nil, first_err or "Failed to fetch comments")
			return
		end

		local files_by_path = {}
		if type(changes_result) == "table" then
			local parts = {}
			for _, change in ipairs(changes_result.changes or {}) do
				if type(change) == "table" then
					table.insert(parts, rebuild_unified_diff(change))
				end
			end
			if #parts > 0 then
				files_by_path = index_files(diff_parser.parse(table.concat(parts, "\n")))
			end
		end

		local comments = {}
		for _, discussion in ipairs(discussions_result) do
			local notes = type(discussion.notes) == "table" and discussion.notes or {}
			if #notes > 0 then
				local first = notes[1]
				-- Only inline (diff-positional) discussions belong here.
				if first.system ~= true and type(first.position) == "table" then
					local resolved = first.resolved == true
					local discussion_id = tostring(discussion.id or "")
					for _, note in ipairs(notes) do
						if note.system ~= true then
							table.insert(
								comments,
								normalize_note(note, first.id, discussion_id, resolved, files_by_path)
							)
						end
					end
				end
			end
		end
		service.set_memory_cache(cache_key, comments)
		on_done(comments, nil)
	end

	local function track(h)
		if h then
			table.insert(handles, h)
		end
	end

	local function step()
		if cancelled then
			return
		end
		pending = pending - 1
		if pending <= 0 then
			finalize()
		end
	end

	track(service.request("GET", discussions_ep, nil, function(result, err)
		if err then
			first_err = first_err or err
		else
			discussions_result = type(result) == "table" and result or {}
		end
		step()
	end))
	track(service.request("GET", changes_ep, nil, function(result, err)
		if err then
			-- diff context is optional; ignore errors
			changes_result = nil
		else
			changes_result = result
		end
		step()
	end))

	return {
		cancel = function()
			cancelled = true
			for _, h in ipairs(handles) do
				if h and h.cancel then
					h.cancel()
				end
			end
		end,
	}
end

local function bust_caches(path, iid)
	service.delete_memory_cache(string.format("gitlab_pulls:comments:%s!%d", path, iid))
	service.delete_memory_cache(string.format("gitlab_pulls:general_comments:%s!%d", path, iid))
end

---@param pr PullRequest
---@param content string
---@param opts PullsAddCommentOpts|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(pr, content, opts, on_done)
	opts = opts or {}
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(nil, "Invalid MR identifier")
		return nil
	end
	if type(content) ~= "string" or vim.trim(content) == "" then
		on_done(nil, "Empty body")
		return nil
	end

	local parent = opts.parent
	local endpoint
	if parent and type(parent._raw) == "table" then
		local discussion_id = tostring(parent._raw.discussion_id or "")
		if discussion_id ~= "" then
			endpoint = string.format(
				"/projects/%s/merge_requests/%d/discussions/%s/notes",
				service.url_encode(path),
				iid,
				discussion_id
			)
		end
	end
	endpoint = endpoint or string.format("/projects/%s/merge_requests/%d/notes", service.url_encode(path), iid)

	return service.request("POST", endpoint, { body = content }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		bust_caches(path, iid)
		local first_id = parent and parent.id or result.id
		local discussion_id
		if parent and type(parent._raw) == "table" then
			discussion_id = tostring(parent._raw.discussion_id or "")
		end
		on_done(normalize_note(result, first_id, discussion_id, false, {}), nil)
	end)
end

---@param pr PullRequest
---@param parent PullsComment
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.reply_comment(pr, parent, content, on_done)
	return M.add_comment(pr, content, { parent = parent }, on_done)
end

---@param pr PullRequest
---@param comment PullsComment
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(pr, comment, on_done)
	local body = tostring(comment.content_raw or "")
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(nil, "Invalid MR identifier")
		return nil
	end
	local note_id = tonumber(comment.id)
	if note_id == nil then
		on_done(nil, "Invalid note id")
		return nil
	end

	local endpoint = string.format("/projects/%s/merge_requests/%d/notes/%d", service.url_encode(path), iid, note_id)
	return service.request("PUT", endpoint, { body = body }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		bust_caches(path, iid)
		local first_id = comment.parent_id or comment.id
		local discussion_id
		if type(comment._raw) == "table" then
			discussion_id = tostring(comment._raw.discussion_id or "")
		end
		on_done(normalize_note(result, first_id, discussion_id, comment.state == "RESOLVED", {}), nil)
	end)
end

---@param pr PullRequest
---@param comment PullsComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(pr, comment, on_done)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(false, "Invalid MR identifier")
		return nil
	end
	local note_id = tonumber(comment.id)
	if note_id == nil then
		on_done(false, "Invalid note id")
		return nil
	end

	local endpoint = string.format("/projects/%s/merge_requests/%d/notes/%d", service.url_encode(path), iid, note_id)
	return service.request("DELETE", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		bust_caches(path, iid)
		on_done(true, nil)
	end)
end

return M
