local M = {}

local json = require("atlas.core.json")
local service = require("atlas.providers.gitlab.client")
local mapper = require("atlas.pulls.providers.gitlab.api.mapper")
local request_scope = require("atlas.core.requests")

local GENERAL_COMMENTS_QUERY = [[
query($path:ID!,$iid:String!,$after:String){
  project(fullPath:$path){
    mergeRequest(iid:$iid){
      notes(filter:ONLY_COMMENTS,first:100,after:$after){
        pageInfo{hasNextPage endCursor}
        nodes{
          id
          body
          system
          created_at:createdAt
          position{__typename}
          author{id name username}
          award_emoji:awardEmoji(first:100){nodes{name}}
          discussion{
            id
            resolved
            resolved_at:resolvedAt
            resolved_by:resolvedBy{id name username}
            notes(first:1){nodes{id}}
          }
        }
      }
    }
  }
}
]]

---@param id any
---@return string
local function id_tail(id)
	local value = tostring(id or "")
	return value:match("([^/]+)$") or value
end

---@param pr PullRequest
---@return string project_path, integer|nil iid
local function project_iid(pr)
	return pr.repo_full_name, tonumber(pr.id)
end

---@param comment PullsComment
---@param parent PullsComment|nil
---@return PullsComment
local function inherit_thread_context(comment, parent)
	if parent == nil then
		return comment
	end
	comment.parent_id = parent.parent_id or parent.id
	comment.thread_id = comment.thread_id or parent.thread_id
	comment.file = comment.file or parent.file
	comment.inline = comment.inline or parent.inline
	comment.outdated = comment.outdated or parent.outdated
	if comment.state == nil and (parent.state == "RESOLVED" or parent.state == "OUTDATED") then
		comment.state = parent.state
	end
	return comment
end

---@param pr PullRequest
---@param comment PullsComment
---@return PullsComment
local function add_permalink(pr, comment)
	local note_id = tonumber(comment.id)
	local base = tostring((pr.link or {}).html or "")
	if note_id and base ~= "" then
		comment.html_url = string.format("%s#note_%d", base, note_id)
	end
	return comment
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_review_comments(pr, opts, on_done)
	opts = opts or {}
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		vim.schedule(function()
			on_done(nil, "Invalid MR identifier")
		end)
		return nil
	end

	local cache_key = string.format("gitlab_pulls:review-comments:%s!%d", path, iid)
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

	local requests = request_scope.new()
	requests.all({
		discussions = function(done)
			return service.fetch_all_pages(discussions_ep, done, {
				action = "Fetch MR review discussions",
				project_path = path,
				iid = iid,
			})
		end,
		drafts = function(done)
			return service.fetch_all_pages(drafts_ep, done, {
				action = "Fetch MR draft comments",
				project_path = path,
				iid = iid,
			})
		end,
	}, function(values, errors)
		if errors.discussions or errors.drafts then
			on_done(nil, errors.discussions or errors.drafts)
			return
		end

		local result = {}
		local discussion_roots = {}
		for _, discussion in ipairs(values.discussions) do
			local notes = discussion.notes
			if #notes > 0 then
				local first = notes[1]
				if first.system ~= true then
					local discussion_id = tostring(discussion.id or "")
					local root =
						add_permalink(pr, mapper.to_comment(first, first.id, discussion_id, first.resolved == true))
					discussion_roots[discussion_id] = root
					local resolved = first.resolved == true
					table.insert(result, root)
					for i = 2, #notes do
						local note = notes[i]
						if note.system ~= true then
							local comment =
								add_permalink(pr, mapper.to_comment(note, first.id, discussion_id, resolved))
							table.insert(result, inherit_thread_context(comment, root))
						end
					end
				end
			end
		end
		for _, draft in ipairs(values.drafts) do
			local discussion_id = type(draft.discussion_id) == "string" and draft.discussion_id or ""
			local root = discussion_roots[discussion_id]
			local comment = inherit_thread_context(mapper.to_draft_comment(draft, root and root.id or nil), root)
			table.insert(result, comment)
		end
		service.set_memory_cache(cache_key, result)
		on_done(result, nil)
	end)
	return requests
end

local function invalidate_comment_caches(path, iid)
	service.delete_memory_cache(string.format("gitlab_pulls:review-comments:%s!%d", path, iid))
	service.delete_memory_cache(string.format("gitlab_pulls:conversation-comments:%s!%d", path, iid))
	service.delete_memory_cache(string.format("gitlab_pulls:activity:%s!%d", path, iid))
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation_comments(pr, opts, on_done)
	opts = opts or {}
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(nil, "Invalid MR identifier")
		return nil
	end

	local cache_key = string.format("gitlab_pulls:conversation-comments:%s!%d", path, iid)
	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local records = {}
	local after
	local current
	local cancelled = false

	local function fetch_page()
		current = service.graphql(GENERAL_COMMENTS_QUERY, {
			path = path,
			iid = tostring(iid),
			after = after,
		}, function(result, err)
			if cancelled then
				return
			end
			local project = json.safe_table(result and result.project)
			local merge_request = json.nilify(project.mergeRequest)
			if err or not merge_request then
				on_done(nil, err or "GitLab did not return the merge request")
				return
			end

			local notes = json.safe_table(merge_request.notes)
			for _, note in ipairs(json.safe_table(notes.nodes)) do
				local discussion = json.safe_table(note.discussion)
				local root = json.safe_table(json.safe_table(discussion.notes).nodes)[1]
				if note.system ~= true and json.nilify(note.position) == nil and root then
					note.id = id_tail(note.id)
					note.award_emoji = json.safe_table(json.safe_table(note.award_emoji).nodes)
					if type(note.author) == "table" then
						note.author.id = id_tail(note.author.id)
					end
					if note.id == id_tail(root.id) then
						note.resolved_at = discussion.resolved_at
						note.resolved_by = discussion.resolved_by
						if type(note.resolved_by) == "table" then
							note.resolved_by.id = id_tail(note.resolved_by.id)
						end
					end
					table.insert(records, {
						note = note,
						root_id = id_tail(root.id),
						discussion_id = id_tail(discussion.id),
						resolved = discussion.resolved == true,
					})
				end
			end

			local page_info = json.safe_table(notes.pageInfo)
			local end_cursor = json.safe_str(page_info.endCursor) or ""
			if page_info.hasNextPage == true and end_cursor ~= "" then
				after = end_cursor
				fetch_page()
				return
			end

			table.sort(records, function(a, b)
				local left = tostring(a.note.created_at or "")
				local right = tostring(b.note.created_at or "")
				return left == right and tostring(a.note.id) < tostring(b.note.id) or left < right
			end)
			local comments = {}
			local roots = {}
			for _, record in ipairs(records) do
				if record.note.id == record.root_id then
					roots[record.discussion_id] = add_permalink(
						pr,
						mapper.to_comment(record.note, record.root_id, record.discussion_id, record.resolved)
					)
				end
			end
			for _, record in ipairs(records) do
				local root_comment = roots[record.discussion_id]
				local is_root = record.note.id == record.root_id
				local comment = is_root and root_comment
					or inherit_thread_context(
						add_permalink(
							pr,
							mapper.to_comment(record.note, record.root_id, record.discussion_id, record.resolved)
						),
						root_comment
					)
				if comment then
					table.insert(comments, comment)
				end
			end
			service.set_memory_cache(cache_key, comments)
			on_done(comments, nil)
		end, {
			action = "Fetch MR comments",
			project_path = path,
			iid = iid,
		})
	end

	fetch_page()
	return {
		cancel = function()
			cancelled = true
			if current then
				current.cancel()
			end
		end,
	}
end

---@param value any Decoded API value.
---@return GitLabPullRequestDiffRefs|nil
local function normalize_diff_refs(value)
	value = json.safe_table(value)
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
---@param target PullsInlineCommentPosition|PullsFileCommentPosition
---@param file_level boolean
---@param pending boolean
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }
local function add_positioned_comment(pr, path, iid, content, target, file_level, pending, on_done)
	---@cast pr GitLabPullRequest
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
			position_type = file_level and "file" or "text",
			base_sha = refs.base_sha,
			head_sha = refs.head_sha,
			start_sha = refs.start_sha,
			old_path = target.old_path or target.path,
			new_path = target.path,
			old_line = not file_level and target.from or nil,
			new_line = not file_level and target.to or nil,
		}
		local start_from, start_to = target.start_from, target.start_to
		if not file_level and (start_from or start_to) then
			local line_code = require("atlas.pulls.providers.gitlab.api.line_code")
			local side = target.to and "new" or "old"
			position.line_range = {
				start = {
					line_code = line_code.encode(target.path, start_from, start_to),
					type = side,
					old_line = start_from,
					new_line = start_to,
				},
				["end"] = {
					line_code = line_code.encode(target.path, target.from, target.to),
					type = side,
					old_line = target.from,
					new_line = target.to,
				},
			}
		end
		local resource = pending and "draft_notes" or "discussions"
		local endpoint = string.format("/projects/%s/merge_requests/%d/%s", service.url_encode(path), iid, resource)
		local payload = pending and { note = content, position = position } or { body = content, position = position }
		track(service.request("POST", endpoint, payload, function(result, err)
			if err then
				finish(nil, err)
				return
			end
			if pending then
				invalidate_comment_caches(path, iid)
				finish(mapper.to_draft_comment(result, nil), nil)
				return
			end
			local first = result.notes[1]
			if not first then
				finish(nil, "Created discussion has no comment")
				return
			end
			invalidate_comment_caches(path, iid)
			finish(add_permalink(pr, mapper.to_comment(first, first.id, tostring(result.id or ""), false)), nil)
		end, {
			action = pending and "Add MR draft comment" or "Add MR discussion",
			project_path = path,
			iid = iid,
		}))
	end

	local refs = normalize_diff_refs(pr.diff_refs)
	if refs and target.commit_hash and refs.head_sha ~= target.commit_hash then
		refs = nil
	end
	if refs then
		create(refs)
	else
		local endpoint =
			string.format("/projects/%s/merge_requests/%d/versions?per_page=1", service.url_encode(path), iid)
		track(service.request("GET", endpoint, nil, function(result, err)
			if err then
				finish(nil, err)
				return
			end
			local latest_refs = normalize_diff_refs(result[1])
			if not latest_refs then
				finish(nil, "Unable to load merge request diff refs")
				return
			end
			if target.commit_hash and latest_refs.head_sha ~= target.commit_hash then
				finish(nil, "Merge request head changed")
				return
			end
			pr.diff_refs = latest_refs
			create(latest_refs)
		end, {
			action = "Fetch MR diff refs",
			project_path = path,
			iid = iid,
		}))
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
	local parent = opts.parent
	if parent and parent.state == "PENDING" and tostring(parent.thread_id or "") == "" then
		on_done(nil, "GitLab cannot reply to this draft until it is published")
		return nil
	end
	local target = opts.inline or opts.file
	if target then
		return add_positioned_comment(pr, path, iid, content, target, opts.file ~= nil, opts.pending == true, on_done)
	end

	if opts.pending then
		local endpoint = string.format("/projects/%s/merge_requests/%d/draft_notes", service.url_encode(path), iid)
		local payload = { note = content }
		if parent then
			local discussion_id = tostring(parent.thread_id or "")
			if discussion_id ~= "" then
				payload.in_reply_to_discussion_id = discussion_id
			end
		end
		return service.request("POST", endpoint, payload, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			invalidate_comment_caches(path, iid)
			local root_id = parent and (parent.parent_id or parent.id) or nil
			local created = mapper.to_draft_comment(result, root_id)
			on_done(inherit_thread_context(created, parent), nil)
		end, {
			action = "Add MR draft comment",
			project_path = path,
			iid = iid,
		})
	end

	local discussion_id = parent and tostring(parent.thread_id or "") or ""
	if parent and discussion_id == "" then
		on_done(nil, "Missing discussion id")
		return nil
	end
	local endpoint = parent
			and string.format(
				"/projects/%s/merge_requests/%d/discussions/%s/notes",
				service.url_encode(path),
				iid,
				service.url_encode(discussion_id)
			)
		or string.format("/projects/%s/merge_requests/%d/discussions", service.url_encode(path), iid)

	return service.request("POST", endpoint, { body = content }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local note = parent and result or result.notes[1]
		if not note then
			on_done(nil, "Empty response")
			return
		end
		invalidate_comment_caches(path, iid)
		local first_id = parent and (parent.parent_id or parent.id) or note.id
		local created_discussion_id = parent and discussion_id or tostring(result.id or "")
		on_done(
			inherit_thread_context(
				add_permalink(pr, mapper.to_comment(note, first_id, created_discussion_id, false)),
				parent
			),
			nil
		)
	end, {
		action = parent and "Reply to MR discussion" or "Add MR discussion",
		project_path = path,
		iid = iid,
	})
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
	local discussion_id = tostring(comment.thread_id or "")
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
	local endpoint, draft = comment_endpoint(path, iid, comment)
	if not endpoint then
		on_done(nil, "Invalid note id")
		return nil
	end

	local payload = draft and { note = body } or { body = body }
	return service.request("PUT", endpoint, payload, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		invalidate_comment_caches(path, iid)
		local updated
		if draft then
			updated = mapper.to_draft_comment(result, comment.parent_id)
		else
			local first_id = comment.parent_id or comment.id
			local discussion_id = tostring(comment.thread_id or "")
			updated = add_permalink(pr, mapper.to_comment(result, first_id, discussion_id, comment.state == "RESOLVED"))
		end
		updated.parent_id = comment.parent_id
		updated.thread_id = updated.thread_id or comment.thread_id
		updated.file = updated.file or comment.file
		updated.inline = updated.inline or comment.inline
		updated.state = updated.state or comment.state
		updated.outdated = updated.outdated or comment.outdated
		on_done(updated, nil)
	end, {
		action = "Edit MR comment",
		project_path = path,
		iid = iid,
		note_id = tostring(comment.id),
	})
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
		invalidate_comment_caches(path, iid)
		on_done(true, nil)
	end, {
		action = "Delete MR comment",
		project_path = path,
		iid = iid,
		note_id = tostring(comment.id),
	})
end

---@param pr PullRequest
---@param root PullsComment
---@param resolved boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_thread_resolved(pr, root, resolved, on_done)
	local path, iid = project_iid(pr)
	local discussion_id = tostring(root.thread_id or "")
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
		invalidate_comment_caches(path, iid)
		on_done(true, nil)
	end, {
		action = resolved and "Resolve MR discussion" or "Reopen MR discussion",
		project_path = path,
		iid = iid,
		discussion_id = discussion_id,
	})
end

---@param pr PullRequest
---@param item PullsConversationItem
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_reaction(pr, item, key, on_done)
	if item.kind ~= "comment" then
		on_done(false, "This item does not support reactions")
		return nil
	end
	---@type PullsComment
	local comment = item.entity
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
		invalidate_comment_caches(path, iid)
		on_done(true, nil)
	end, {
		action = "Add MR comment reaction",
		project_path = path,
		iid = iid,
		note_id = note_id,
	})
end

return M
