local M = {}

local gitlab_reactions = require("atlas.providers.gitlab.reactions")
local json = require("atlas.core.json")
local service = require("atlas.providers.gitlab.client")
local mapper = require("atlas.pulls.providers.gitlab.api.mapper")
local request_scope = require("atlas.core.requests")

local REVIEW_COMMENTS_QUERY = [[
query($path:ID!,$iid:String!,$after:String){
  currentUser{username}
  project(fullPath:$path){
    mergeRequest(iid:$iid){
      notes(filter:ONLY_COMMENTS,first:100,after:$after){
        pageInfo{hasNextPage endCursor}
        nodes{
          id
          body
          createdAt
          url
          maxAccessLevelOfAuthor
          authorIsContributor
          author{id name username bot}
          awardEmoji(first:100){nodes{name user{name username}}}
          position{positionType oldPath newPath oldLine newLine diffRefs{headSha}}
          discussion{
            id
            resolved
            resolvedAt
            resolvedBy{id name username}
            notes(first:1){nodes{id}}
            truncatedDiffLines{type oldLine newLine text}
          }
        }
      }
    }
  }
}
]]

local GENERAL_COMMENTS_QUERY = [[
query($path:ID!,$iid:String!,$after:String){
  currentUser{username}
  project(fullPath:$path){
    mergeRequest(iid:$iid){
      id
      description
      createdAt
      webUrl
      author{id name username}
      awardEmoji(first:100){nodes{name user{name username}}}
      notes(filter:ONLY_COMMENTS,first:100,after:$after){
        pageInfo{hasNextPage endCursor}
        nodes{
          id
          body
          system
          createdAt
          url
          position{positionType}
          maxAccessLevelOfAuthor
          authorIsContributor
          author{id name username bot}
          awardEmoji(first:100){nodes{name user{name username}}}
          discussion{
            id
            resolved
            resolvedAt
            resolvedBy{id name username}
            notes(first:1){nodes{id}}
          }
        }
      }
    }
  }
}
]]

local CREATE_NOTE_MUTATION = [[
mutation($noteableId:NoteableID!,$body:String!,$discussionId:DiscussionID){
  createNote(input:{noteableId:$noteableId,body:$body,discussionId:$discussionId}){
    errors
    note{
      id
      body
      createdAt
      url
      maxAccessLevelOfAuthor
      authorIsContributor
      author{id name username bot}
      discussion{
        id
        resolved
        resolvedAt
        resolvedBy{id name username}
        notes(first:1){nodes{id}}
      }
    }
  }
}
]]

local UPDATE_NOTE_MUTATION = [[
mutation($id:NoteID!,$body:String!){
  updateNote(input:{id:$id,body:$body}){
    errors
    note{body}
  }
}
]]

local DESTROY_NOTE_MUTATION = [[
mutation($id:NoteID!){
  destroyNote(input:{id:$id}){errors}
}
]]

local RESOLVE_DISCUSSION_MUTATION = [[
mutation($id:DiscussionID!,$resolve:Boolean!){
  discussionToggleResolve(input:{id:$id,resolve:$resolve}){errors}
}
]]

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
	local discussions_ep = string.format("/projects/%s/merge_requests/%d/discussions", encoded, iid)
	local drafts_ep = string.format("/projects/%s/merge_requests/%d/draft_notes", encoded, iid)

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
		local roots = {}
		for _, discussion in ipairs(values.discussions) do
			local notes = discussion.notes
			if #notes > 0 and notes[1].system ~= true then
				local root = mapper.to_discussion_note(notes[1], discussion, pr.link.html, pr.author.username)
				roots[root.thread_id] = root
				table.insert(result, root)
				for i = 2, #notes do
					if notes[i].system ~= true then
						local comment =
							mapper.to_discussion_note(notes[i], discussion, pr.link.html, pr.author.username)
						table.insert(result, inherit_thread_context(comment, root))
					end
				end
			end
		end
		for _, draft in ipairs(values.drafts) do
			local comment = mapper.to_draft_comment(draft)
			table.insert(result, inherit_thread_context(comment, roots[comment.thread_id]))
		end
		service.set_memory_cache(cache_key, result)
		on_done(result, nil)
	end)
	return requests
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(result: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_review_threads(pr, opts, on_done)
	local path, iid = project_iid(pr)
	local cache_key = string.format("gitlab_pulls:review-threads:%s!%d", path, iid)
	if not (opts and opts.force_refresh) then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local viewer
	local requests = request_scope.new()
	requests.all({
		notes = function(done)
			local records = {}
			local pages = request_scope.new()
			local function fetch_page(after)
				pages.run(function(callback)
					return service.graphql(
						REVIEW_COMMENTS_QUERY,
						{
							path = path,
							iid = tostring(iid),
							after = after,
						},
						callback,
						{
							action = "Fetch MR review threads",
							project_path = path,
							iid = iid,
						}
					)
				end, function(result, err)
					local project = json.nilify(result and result.project)
					local merge_request = project and json.nilify(project.mergeRequest)
					if err or not merge_request then
						done(nil, err or "GitLab did not return the merge request")
						return
					end
					viewer = json.safe_str(json.safe_table(result.currentUser).username)
					local notes = merge_request.notes
					vim.list_extend(records, notes.nodes)
					if notes.pageInfo.hasNextPage then
						fetch_page(notes.pageInfo.endCursor)
					else
						done(records, nil)
					end
				end)
			end
			fetch_page(nil)
			return pages
		end,
		drafts = function(done)
			local endpoint = string.format("/projects/%s/merge_requests/%d/draft_notes", service.url_encode(path), iid)
			return service.fetch_all_pages(endpoint, done, {
				action = "Fetch MR draft comments",
				project_path = path,
				iid = iid,
			})
		end,
	}, function(values, errors)
		if errors.notes or errors.drafts then
			on_done(nil, errors.notes or errors.drafts)
			return
		end
		local comments, roots = {}, {}
		for _, note in ipairs(values.notes) do
			local comment = mapper.to_comment(note, viewer, pr.author.username)
			table.insert(comments, comment)
			if comment.parent_id == nil then
				roots[comment.thread_id] = comment
				comment.hunk = mapper.to_diff_hunk(note.discussion.truncatedDiffLines)
			end
		end
		for _, comment in ipairs(comments) do
			if comment.parent_id then
				inherit_thread_context(comment, roots[comment.thread_id])
			end
		end
		for _, draft in ipairs(values.drafts) do
			local comment = mapper.to_draft_comment(draft)
			table.insert(comments, inherit_thread_context(comment, roots[comment.thread_id]))
		end
		service.set_memory_cache(cache_key, comments)
		on_done(comments, nil)
	end)
	return requests
end

---@param path string
---@param iid integer
function M.invalidate_caches(path, iid)
	service.delete_memory_cache(string.format("gitlab_pulls:review-comments:%s!%d", path, iid))
	service.delete_memory_cache(string.format("gitlab_pulls:review-threads:%s!%d", path, iid))
	service.delete_memory_cache(string.format("gitlab_pulls:conversation-comments:%s!%d", path, iid))
	service.delete_memory_cache(string.format("gitlab_pulls:activity:%s!%d", path, iid))
end

---@param path string
---@param iid integer
---@param query string
---@param variables table
---@param mutation string
---@param ctx table
---@param on_done fun(payload: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function mutate(path, iid, query, variables, mutation, ctx, on_done)
	return service.graphql(query, variables, function(data, err)
		local payload = json.safe_table(json.safe_table(data)[mutation])
		local errors = json.safe_table(payload.errors)
		if err or #errors > 0 then
			on_done(nil, err or tostring(errors[1]))
			return
		end
		M.invalidate_caches(path, iid)
		on_done(payload, nil)
	end, vim.tbl_extend("force", { project_path = path, iid = iid }, ctx))
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(conversation: { description: PullsComment|nil, comments: PullsComment[] }|nil, err: string|nil)
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

	local comments = {}
	local description, after
	local requests = request_scope.new()

	local function fetch_page()
		requests.run(function(done)
			return service.graphql(
				GENERAL_COMMENTS_QUERY,
				{
					path = path,
					iid = tostring(iid),
					after = after,
				},
				done,
				{
					action = "Fetch MR comments",
					project_path = path,
					iid = iid,
				}
			)
		end, function(result, err)
			local project = json.safe_table(result and result.project)
			local merge_request = json.nilify(project.mergeRequest)
			if err or not merge_request then
				on_done(nil, err or "GitLab did not return the merge request")
				return
			end

			local viewer = json.safe_str(json.safe_table(result.currentUser).username)
			description = description or mapper.to_description(merge_request, viewer, pr.author.username)
			local notes = json.safe_table(merge_request.notes)
			for _, note in ipairs(json.safe_table(notes.nodes)) do
				if note.system ~= true and json.nilify(note.position) == nil then
					table.insert(comments, mapper.to_comment(note, viewer, pr.author.username))
				end
			end

			local page_info = json.safe_table(notes.pageInfo)
			local end_cursor = json.safe_str(page_info.endCursor) or ""
			if page_info.hasNextPage == true and end_cursor ~= "" then
				after = end_cursor
				fetch_page()
				return
			end

			table.sort(comments, function(a, b)
				return a.created_at == b.created_at and a.id < b.id or a.created_at < b.created_at
			end)
			local roots = {}
			for _, comment in ipairs(comments) do
				if comment.parent_id == nil then
					roots[comment.thread_id] = comment
				end
			end
			for _, comment in ipairs(comments) do
				if comment.parent_id then
					inherit_thread_context(comment, roots[comment.thread_id])
				end
			end
			local conversation = { description = description, comments = comments }
			service.set_memory_cache(cache_key, conversation)
			on_done(conversation, nil)
		end)
	end

	fetch_page()
	return requests
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
	local requests = request_scope.new()
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
		requests.run(function(done)
			return service.request("POST", endpoint, payload, done, {
				action = pending and "Add MR draft comment" or "Add MR discussion",
				project_path = path,
				iid = iid,
			})
		end, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			M.invalidate_caches(path, iid)
			if pending then
				on_done(mapper.to_draft_comment(result), nil)
				return
			end
			local first = result.notes[1]
			if not first then
				on_done(nil, "Created discussion has no comment")
				return
			end
			on_done(mapper.to_discussion_note(first, result, pr.link.html, pr.author.username), nil)
		end)
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
		requests.run(function(done)
			return service.request("GET", endpoint, nil, done, {
				action = "Fetch MR diff refs",
				project_path = path,
				iid = iid,
			})
		end, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			local latest_refs = normalize_diff_refs(result[1])
			if not latest_refs then
				on_done(nil, "Unable to load merge request diff refs")
				return
			end
			if target.commit_hash and latest_refs.head_sha ~= target.commit_hash then
				on_done(nil, "Merge request head changed")
				return
			end
			pr.diff_refs = latest_refs
			create(latest_refs)
		end)
	end

	return requests
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
	if parent and parent.pending and (parent.thread_id or "") == "" then
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
		if parent and parent.thread_id then
			payload.in_reply_to_discussion_id = parent.thread_id:match("[^/]+$")
		end
		return service.request("POST", endpoint, payload, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			M.invalidate_caches(path, iid)
			on_done(inherit_thread_context(mapper.to_draft_comment(result), parent), nil)
		end, {
			action = "Add MR draft comment",
			project_path = path,
			iid = iid,
		})
	end

	if parent and not parent.thread_id then
		on_done(nil, "Missing discussion id")
		return nil
	end
	---@cast pr GitLabPullRequest
	local variables = { noteableId = pr.node_id, body = content, discussionId = parent and parent.thread_id }
	local ctx = { action = parent and "Reply to MR discussion" or "Add MR discussion" }
	return mutate(path, iid, CREATE_NOTE_MUTATION, variables, "createNote", ctx, function(payload, err)
		local note = payload and json.nilify(payload.note)
		if not note then
			on_done(nil, err or "GitLab did not return the created comment")
			return
		end
		on_done(inherit_thread_context(mapper.to_comment(note, nil, pr.author.username), parent), nil)
	end)
end

---@param path string
---@param iid integer
---@param comment PullsComment
---@return string
local function draft_endpoint(path, iid, comment)
	return string.format("/projects/%s/merge_requests/%d/draft_notes/%s", service.url_encode(path), iid, comment.id)
end

---@param pr PullRequest
---@param comment PullsComment
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(pr, comment, content, on_done)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(nil, "Invalid MR identifier")
		return nil
	end
	if comment.pending then
		return service.request("PUT", draft_endpoint(path, iid, comment), { note = content }, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			M.invalidate_caches(path, iid)
			on_done(vim.tbl_extend("force", comment, { body = tostring(result.note or content) }), nil)
		end, {
			action = "Edit MR draft comment",
			project_path = path,
			iid = iid,
			draft_note_id = comment.id,
		})
	end

	local ctx = { action = "Edit MR comment", note_id = comment.id }
	return mutate(
		path,
		iid,
		UPDATE_NOTE_MUTATION,
		{ id = comment.id, body = content },
		"updateNote",
		ctx,
		function(payload, err)
			local note = payload and json.nilify(payload.note)
			if not note then
				on_done(nil, err or "GitLab did not return the updated comment")
				return
			end
			on_done(vim.tbl_extend("force", comment, { body = tostring(note.body or content) }), nil)
		end
	)
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
	if comment.pending then
		return service.request("DELETE", draft_endpoint(path, iid, comment), nil, function(_, err)
			if not err then
				M.invalidate_caches(path, iid)
			end
			on_done(err == nil, err)
		end, {
			action = "Delete MR draft comment",
			project_path = path,
			iid = iid,
			draft_note_id = comment.id,
		})
	end

	local ctx = { action = "Delete MR comment", note_id = comment.id }
	return mutate(path, iid, DESTROY_NOTE_MUTATION, { id = comment.id }, "destroyNote", ctx, function(_, err)
		on_done(err == nil, err)
	end)
end

---@param pr PullRequest
---@param root PullsComment
---@param resolved boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_thread_resolved(pr, root, resolved, on_done)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(false, "Invalid MR identifier")
		return nil
	end
	if not root.thread_id then
		on_done(false, "Missing discussion id")
		return nil
	end
	local variables = { id = root.thread_id, resolve = resolved }
	local ctx = { action = resolved and "Resolve MR discussion" or "Reopen MR discussion" }
	return mutate(path, iid, RESOLVE_DISCUSSION_MUTATION, variables, "discussionToggleResolve", ctx, function(_, err)
		on_done(err == nil, err)
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
	return gitlab_reactions.add(comment, key, function(ok, err)
		if ok then
			M.invalidate_caches(path, iid)
		end
		on_done(ok, err)
	end)
end

---@param pr PullRequest
---@param comment PullsComment
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.remove_reaction(pr, comment, key, on_done)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(false, "Invalid MR identifier")
		return nil
	end
	return gitlab_reactions.remove(comment, key, function(ok, err)
		if ok then
			M.invalidate_caches(path, iid)
		end
		on_done(ok, err)
	end)
end

return M
