local M = {}

local service = require("atlas.pulls.providers.gitlab.api.service")
local diff_parser = require("atlas.core.git.diff_parser")
local mapper = require("atlas.pulls.providers.gitlab.api.mapper")

---@param pr PullRequest
---@return string project_path, integer|nil iid
local function project_iid(pr)
	return pr.repo_full_name, tonumber(pr.id)
end

---@param files DiffFile[]
---@return table<string, DiffFile>
local function index_files(files)
	local by_path = {}
	for _, f in ipairs(files or {}) do
		if f.path ~= "" then
			by_path[f.path] = f
		end
		if f.old_path and f.old_path ~= "" and by_path[f.old_path] == nil then
			by_path[f.old_path] = f
		end
	end
	return by_path
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

local GQL_DISCUSSIONS = [[
	query ($fullPath: ID!, $iid: String!) {
		project(fullPath: $fullPath) {
			mergeRequest(iid: $iid) {
				discussions {
					nodes {
						id
						notes {
							nodes {
								id
								body
								system
								resolved
								createdAt
								author { username name }
								position { positionType newPath oldPath newLine oldLine }
								awardEmoji { nodes { name } }
							}
						}
					}
				}
			}
		}
	}
]]

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

	return service.graphql(GQL_DISCUSSIONS, { fullPath = path, iid = tostring(iid) }, function(data, err)
		if err then
			on_done(nil, err)
			return
		end

		local mr = data and data.project and data.project.mergeRequest or nil
		local comments = {}

		local function id_tail(gid)
			return tostring(gid or ""):match("([^/]+)$") or ""
		end

		for _, d in ipairs((((mr or {}).discussions or {}).nodes or {})) do
			local notes = ((d.notes or {}).nodes or {})
			if #notes > 0 then
				local first = notes[1]
				if first.system ~= true and type(first.position) ~= "table" then
					local first_id = tonumber(id_tail(first.id))
					local discussion_id = id_tail(d.id)
					for _, n in ipairs(notes) do
						if n.system ~= true then
							table.insert(comments, mapper.to_comment_from_gql(n, first_id, discussion_id))
						end
					end
				end
			end
		end
		service.set_memory_cache(cache_key, comments)
		on_done(comments, nil)
	end)
end

---@param endpoint string
---@param on_done fun(result: table[]|nil, err: string|nil)
---@return { cancel: fun() }
local function fetch_all_pages(endpoint, on_done)
	local values = {}
	local current
	local cancelled = false
	local page = 1

	local function fetch_page()
		if cancelled then
			return
		end

		current = service.request("GET", string.format("%s&page=%d", endpoint, page), nil, function(result, err)
			if cancelled then
				return
			end
			if err or type(result) ~= "table" then
				on_done(nil, err or "Invalid paginated response")
				return
			end

			vim.list_extend(values, result)
			if #result < 100 then
				on_done(values, nil)
				return
			end

			page = page + 1
			fetch_page()
		end)
	end

	fetch_page()
	return {
		cancel = function()
			cancelled = true
			if current and current.cancel then
				current.cancel()
			end
		end,
	}
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
	local drafts_ep = string.format("/projects/%s/merge_requests/%d/draft_notes?per_page=100", encoded, iid)
	local changes_ep = string.format("/projects/%s/merge_requests/%d/changes", encoded, iid)

	local pending = 3
	local discussions_result, drafts_result, changes_result
	local first_err
	local drafts_failed = false
	local handles = {}
	local cancelled = false

	local function finalize()
		if cancelled then
			return
		end
		if first_err or discussions_result == nil or drafts_result == nil then
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
		local discussion_first_ids = {}
		for _, discussion in ipairs(discussions_result) do
			local notes = type(discussion.notes) == "table" and discussion.notes or {}
			if #notes > 0 then
				local first = notes[1]
				local discussion_id = tostring(discussion.id or "")
				local root = mapper.to_comment(first, first.id, discussion_id, first.resolved == true, files_by_path)
				if first.system ~= true and root.inline then
					discussion_first_ids[discussion_id] = first.id
					local resolved = first.resolved == true
					table.insert(comments, root)
					for i = 2, #notes do
						local note = notes[i]
						if note.system ~= true then
							table.insert(
								comments,
								mapper.to_comment(note, first.id, discussion_id, resolved, files_by_path)
							)
						end
					end
				end
			end
		end
		for _, draft in ipairs(drafts_result or {}) do
			local discussion_id = type(draft.discussion_id) == "string" and draft.discussion_id or ""
			local first_id = discussion_first_ids[discussion_id]
			local comment = mapper.to_draft_comment(draft, first_id, files_by_path)
			if comment.inline or first_id then
				table.insert(comments, comment)
			end
		end
		if not drafts_failed then
			service.set_memory_cache(cache_key, comments)
		end
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

	track(fetch_all_pages(discussions_ep, function(result, err)
		if err then
			first_err = first_err or err
		else
			discussions_result = result
		end
		step()
	end))
	track(fetch_all_pages(drafts_ep, function(result, err)
		if err then
			drafts_failed = true
			drafts_result = {}
		else
			drafts_result = result
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

---@param comment PullsComment
---@param parent PullsComment|nil
---@return PullsComment
local function inherit_thread_context(comment, parent)
	if parent == nil then
		return comment
	end
	comment.parent_id = parent.parent_id or parent.id
	comment.inline = comment.inline or parent.inline
	comment.inline_hunk = comment.inline_hunk or parent.inline_hunk
	if comment.state == nil and (parent.state == "RESOLVED" or parent.state == "OUTDATED") then
		comment.state = parent.state
	end
	return comment
end

---@param value any Decoded API value.
---@return { base_sha: string, head_sha: string, start_sha: string }|nil
local function normalize_diff_refs(value)
	value = type(value) == "table" and value or {}
	local refs = {
		base_sha = tostring(value.base_sha or value.base_commit_sha or ""),
		head_sha = tostring(value.head_sha or value.head_commit_sha or ""),
		start_sha = tostring(value.start_sha or value.start_commit_sha or ""),
	}
	if refs.base_sha == "" or refs.head_sha == "" or refs.start_sha == "" then
		return nil
	end
	return refs
end

---@param pr PullRequest
---@param path string
---@param iid integer
---@param content string
---@param inline PullsInlineCommentPosition
---@param pending boolean
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }
local function add_inline_comment(pr, path, iid, content, inline, pending, on_done)
	local cancelled = false
	local request
	local function track(handle)
		request = handle
		if cancelled and request then
			request.cancel()
		end
	end
	local function finish(comment, err)
		if not cancelled then
			on_done(comment, err)
		end
	end
	local function create(refs)
		local position = {
			position_type = "text",
			base_sha = refs.base_sha,
			head_sha = refs.head_sha,
			start_sha = refs.start_sha,
			old_path = inline.old_path or inline.path,
			new_path = inline.path,
		}
		position[inline.side == "old" and "old_line" or "new_line"] = inline.line
		local resource = pending and "draft_notes" or "discussions"
		local endpoint = string.format("/projects/%s/merge_requests/%d/%s", service.url_encode(path), iid, resource)
		local payload = pending and { note = content, position = position } or { body = content, position = position }
		track(service.request("POST", endpoint, payload, function(result, err)
			if err or type(result) ~= "table" then
				finish(nil, err or "Empty response")
				return
			end
			if pending then
				bust_caches(path, iid)
				finish(mapper.to_draft_comment(result, nil, {}), nil)
				return
			end
			local first = type(result.notes) == "table" and result.notes[1] or nil
			if type(first) ~= "table" then
				finish(nil, "Created discussion has no comment")
				return
			end
			bust_caches(path, iid)
			finish(mapper.to_comment(first, first.id, tostring(result.id or ""), false, {}), nil)
		end))
	end

	local raw = pr._raw
	local refs = normalize_diff_refs(raw.diff_refs)
	if refs and inline.commit_hash and refs.head_sha ~= inline.commit_hash then
		refs = nil
	end
	if refs then
		create(refs)
	else
		local endpoint =
			string.format("/projects/%s/merge_requests/%d/versions?per_page=1", service.url_encode(path), iid)
		track(service.request("GET", endpoint, nil, function(result, err)
			local latest = type(result) == "table" and result[1] or nil
			local latest_refs = normalize_diff_refs(latest)
			if err or not latest_refs then
				finish(nil, err or "Unable to load merge request diff refs")
				return
			end
			if inline.commit_hash and latest_refs.head_sha ~= inline.commit_hash then
				finish(nil, "Merge request head changed")
				return
			end
			raw.diff_refs = latest_refs
			create(latest_refs)
		end))
	end

	return {
		cancel = function()
			cancelled = true
			if request then
				request.cancel()
			end
		end,
	}
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
	if vim.trim(content) == "" then
		on_done(nil, "Empty body")
		return nil
	end
	if opts.inline then
		return add_inline_comment(pr, path, iid, content, opts.inline, opts.pending == true, on_done)
	end

	local parent = opts.parent
	if opts.pending then
		local endpoint = string.format("/projects/%s/merge_requests/%d/draft_notes", service.url_encode(path), iid)
		local payload = { note = content }
		if parent and parent._raw then
			local discussion_id = tostring(parent._raw.discussion_id or "")
			if discussion_id ~= "" then
				payload.in_reply_to_discussion_id = discussion_id
			end
		end
		return service.request("POST", endpoint, payload, function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Empty response")
				return
			end
			bust_caches(path, iid)
			local root_id = parent and (parent.parent_id or parent.id) or nil
			local created = mapper.to_draft_comment(result, root_id, {})
			on_done(inherit_thread_context(created, parent), nil)
		end)
	end

	local endpoint
	if parent and parent._raw then
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
		local first_id = parent and (parent.parent_id or parent.id) or result.id
		local discussion_id
		if parent and parent._raw then
			discussion_id = tostring(parent._raw.discussion_id or "")
		end
		on_done(inherit_thread_context(mapper.to_comment(result, first_id, discussion_id, false, {}), parent), nil)
	end)
end

---@param pr PullRequest
---@param parent PullsComment
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.reply_comment(pr, parent, content, on_done)
	local raw = parent._raw or {}
	if parent.state == "PENDING" and tostring(raw.discussion_id or "") == "" then
		on_done(nil, "GitLab cannot reply to this draft until it is published")
		return nil
	end
	return M.add_comment(pr, content, { parent = parent, pending = parent.state == "PENDING" }, on_done)
end

---@param path string
---@param iid integer
---@param comment PullsComment
---@return string|nil endpoint
---@return boolean draft
local function comment_endpoint(path, iid, comment)
	local raw = comment._raw or {}
	local draft_note_id = tonumber(raw.draft_note_id)
	local note_id = draft_note_id or tonumber(comment.id)
	if not note_id then
		return nil, false
	end

	local prefix = string.format("/projects/%s/merge_requests/%d", service.url_encode(path), iid)
	if draft_note_id then
		return string.format("%s/draft_notes/%d", prefix, note_id), true
	end
	local discussion_id = tostring(raw.discussion_id or "")
	if discussion_id ~= "" then
		return string.format("%s/discussions/%s/notes/%d", prefix, service.url_encode(discussion_id), note_id), false
	end
	return string.format("%s/notes/%d", prefix, note_id), false
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
	local raw = comment._raw or {}
	local endpoint, draft = comment_endpoint(path, iid, comment)
	if not endpoint then
		on_done(nil, "Invalid note id")
		return nil
	end

	local payload = draft and { note = body } or { body = body }
	return service.request("PUT", endpoint, payload, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		bust_caches(path, iid)
		if draft then
			on_done(mapper.to_draft_comment(result, comment.parent_id, {}), nil)
			return
		end
		local first_id = comment.parent_id or comment.id
		local discussion_id = tostring(raw.discussion_id or "")
		on_done(mapper.to_comment(result, first_id, discussion_id, comment.state == "RESOLVED", {}), nil)
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
	local endpoint = comment_endpoint(path, iid, comment)
	if not endpoint then
		on_done(false, "Invalid note id")
		return nil
	end

	return service.request("DELETE", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		bust_caches(path, iid)
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param root PullsComment
---@param resolved boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_thread_resolved(pr, root, resolved, on_done)
	local path, iid = project_iid(pr)
	local raw = root._raw or {}
	local discussion_id = tostring(raw.discussion_id or "")
	if path == "" or iid == nil then
		on_done(false, "Invalid MR identifier")
		return nil
	end
	if discussion_id == "" then
		on_done(false, "Missing discussion id")
		return nil
	end

	local endpoint = string.format(
		"/projects/%s/merge_requests/%d/discussions/%s",
		service.url_encode(path),
		iid,
		service.url_encode(discussion_id)
	)
	return service.request("PUT", endpoint, { resolved = resolved }, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		bust_caches(path, iid)
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param comment PullsComment
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_reaction(pr, comment, key, on_done)
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
	local endpoint = string.format(
		"/projects/%s/merge_requests/%d/notes/%d/award_emoji?name=%s",
		service.url_encode(path),
		iid,
		note_id,
		service.url_encode(key)
	)
	return service.request("POST", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end)
end

return M
