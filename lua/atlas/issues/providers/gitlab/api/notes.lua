local M = {}

local service = require("atlas.providers.gitlab.client")
local normalizer = require("atlas.issues.providers.gitlab.api.mapper")
local json = require("atlas.core.json")

local GQL_DISCUSSIONS = [[
	query ($fullPath: ID!, $iid: String!) {
		project(fullPath: $fullPath) {
			issue(iid: $iid) {
				discussions {
					nodes {
						id
						notes {
							nodes {
								id
								body
								system
								createdAt
								updatedAt
								author { username name }
								awardEmoji { nodes { name } }
							}
						}
					}
				}
			}
		}
	}
]]

---@param gid string|nil    full GraphQL gid like "gid://gitlab/Note/123"
---@return string
local function id_tail(gid)
	return tostring(gid or ""):match("([^/]+)$") or ""
end

---@param path string
---@param iid integer
---@return string
local function discussions_cache_key(path, iid)
	return string.format("gitlab:discussions:%s#%d", path, iid)
end

---@param issue Issue
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(discussions: table[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_discussions(issue, opts, on_done)
	opts = opts or {}
	local path, iid = normalizer.parse_key(tostring(issue.key or ""))
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end

	local cache_key = discussions_cache_key(path, iid)
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
		local project = json.safe_table(data).project
		local raw_issue = json.safe_table(project).issue
		local discussions = json.safe_table(raw_issue).discussions
		local nodes = json.safe_table(json.safe_table(discussions).nodes)
		service.set_memory_cache(cache_key, nodes)
		on_done(nodes, nil)
	end, {
		action = "Fetch discussions (GQL)",
		path = path,
		iid = iid,
	})
end

---@param discussions table[]
---@return IssueComment[], IssueActivityEntry[]
local function map_discussions(discussions)
	local comments = {}
	local events = {}
	for _, discussion_value in ipairs(discussions) do
		local discussion = json.safe_table(discussion_value)
		local discussion_id = id_tail(discussion.id)
		local first_id = nil
		for _, raw in ipairs(json.safe_table(json.safe_table(discussion.notes).nodes)) do
			if raw.system == true then
				local entry = normalizer.to_activity_from_note(raw)
				if entry then
					table.insert(events, entry)
				end
			else
				local comment = normalizer.to_comment_from_note(raw, first_id, discussion_id)
				if comment then
					first_id = first_id or comment.id
					table.insert(comments, comment)
				end
			end
		end
	end
	return comments, events
end

---@param issue Issue
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(result: { comments: IssueComment[], events: IssueActivityEntry[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_conversation(issue, opts, on_done)
	return fetch_discussions(issue, opts, function(discussions, err)
		if err or discussions == nil then
			on_done(nil, err)
			return
		end
		local comments, events = map_discussions(discussions)
		on_done({ comments = comments, events = events }, nil)
	end)
end

---@param issue Issue
---@param body string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(issue, body, on_done)
	local path, iid = normalizer.parse_key(tostring(issue.key or ""))
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end
	if vim.trim(body) == "" then
		on_done(nil, "Comment cannot be empty")
		return nil
	end

	local endpoint = string.format("/projects/%s/issues/%d/discussions", service.url_encode(path), iid)
	return service.request("POST", endpoint, { body = body }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		result = json.safe_table(result)
		local discussion_id = tostring(result.id or "")
		local notes = json.safe_table(result.notes)
		local comment = normalizer.to_comment_from_note(notes[1], nil, discussion_id)
		if comment == nil then
			on_done(nil, "GitLab did not return the created comment")
			return
		end
		service.delete_memory_cache(discussions_cache_key(path, iid))
		on_done(comment, nil)
	end, {
		action = "Add discussion",
		path = path,
		iid = iid,
	})
end

---@param issue Issue
---@param parent IssueComment
---@param body string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.reply_comment(issue, parent, body, on_done)
	local path, iid = normalizer.parse_key(tostring(issue.key or ""))
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end
	if vim.trim(body) == "" then
		on_done(nil, "Comment cannot be empty")
		return nil
	end
	local discussion_id = parent._raw and tostring(parent._raw.discussion_id or "") or ""
	if discussion_id == "" then
		return M.add_comment(issue, body, on_done)
	end

	local endpoint =
		string.format("/projects/%s/issues/%d/discussions/%s/notes", service.url_encode(path), iid, discussion_id)
	return service.request("POST", endpoint, { body = body }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		service.delete_memory_cache(discussions_cache_key(path, iid))
		on_done(normalizer.to_comment_from_note(result, parent.id, discussion_id), nil)
	end, {
		action = "Reply in discussion",
		path = path,
		iid = iid,
		discussion_id = discussion_id,
	})
end

---@param issue Issue
---@param comment IssueComment
---@param body string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(issue, comment, body, on_done)
	local path, iid = normalizer.parse_key(tostring(issue.key or ""))
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end
	if vim.trim(body) == "" then
		on_done(nil, "Comment cannot be empty")
		return nil
	end

	local note_id = tostring(comment.id)
	local discussion_id = comment._raw and tostring(comment._raw.discussion_id or "") or ""
	local endpoint = string.format("/projects/%s/issues/%d/notes/%s", service.url_encode(path), iid, note_id)
	if discussion_id ~= "" then
		endpoint = string.format(
			"/projects/%s/issues/%d/discussions/%s/notes/%s",
			service.url_encode(path),
			iid,
			discussion_id,
			note_id
		)
	end
	return service.request("PUT", endpoint, { body = body }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		service.delete_memory_cache(discussions_cache_key(path, iid))
		on_done(
			normalizer.to_comment_from_note(result, comment.parent_id, discussion_id ~= "" and discussion_id or nil),
			nil
		)
	end, {
		action = "Edit note",
		path = path,
		iid = iid,
		note_id = note_id,
	})
end

---@param issue Issue
---@param comment IssueComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(issue, comment, on_done)
	local path, iid = normalizer.parse_key(tostring(issue.key or ""))
	if path == "" or iid == nil then
		on_done(false, "Invalid issue key")
		return nil
	end

	local note_id = tostring(comment.id)
	local discussion_id = comment._raw and tostring(comment._raw.discussion_id or "") or ""
	local endpoint = string.format("/projects/%s/issues/%d/notes/%s", service.url_encode(path), iid, note_id)
	if discussion_id ~= "" then
		endpoint = string.format(
			"/projects/%s/issues/%d/discussions/%s/notes/%s",
			service.url_encode(path),
			iid,
			discussion_id,
			note_id
		)
	end
	return service.request("DELETE", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.delete_memory_cache(discussions_cache_key(path, iid))
		on_done(true, nil)
	end, {
		action = "Delete note",
		path = path,
		iid = iid,
		note_id = note_id,
	})
end

---@param issue Issue
---@param item IssueConversationItem
---@param name string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_reaction(issue, item, name, on_done)
	if item.kind ~= "comment" then
		on_done(false, "Reactions are only supported on comments")
		return nil
	end
	local comment = item.entity
	---@cast comment IssueComment
	local note_id = comment.id
	local path, iid = normalizer.parse_key(tostring(issue.key or ""))
	if path == "" or iid == nil then
		on_done(false, "Invalid issue key")
		return nil
	end
	local endpoint = string.format(
		"/projects/%s/issues/%d/notes/%s/award_emoji?name=%s",
		service.url_encode(path),
		iid,
		tostring(note_id),
		service.url_encode(name)
	)
	return service.request("POST", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.delete_memory_cache(discussions_cache_key(path, iid))
		on_done(true, nil)
	end, {
		action = "Add reaction",
		path = path,
		iid = iid,
		note_id = tostring(note_id),
		name = name,
	})
end

return M
