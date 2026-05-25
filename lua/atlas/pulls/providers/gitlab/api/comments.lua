local M = {}

local service = require("atlas.pulls.providers.gitlab.api.service")
local diff_parser = require("atlas.core.git.diff_parser")
local mapper = require("atlas.pulls.providers.gitlab.api.mapper")

---@param pr PullRequest
---@return string project_path, integer|nil iid
local function project_iid(pr)
	local raw = type(pr._raw) == "table" and pr._raw or {}
	local path = tostring(raw.project_path or pr.repo_full_name or "")
	local iid = tonumber(raw.iid or pr.id)
	return path, iid
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
								mapper.to_comment(note, first.id, discussion_id, resolved, files_by_path)
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
		on_done(mapper.to_comment(result, first_id, discussion_id, false, {}), nil)
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
