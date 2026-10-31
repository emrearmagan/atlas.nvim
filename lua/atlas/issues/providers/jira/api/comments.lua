local M = {}

local service = require("atlas.providers.jira.client")
local normalizer = require("atlas.issues.providers.jira.api.mapper")
local markdown = require("atlas.formats.adf.from_markdown")

---@param raw table
---@param issue Issue
---@return IssueComment[]
local function map_comments(raw, issue)
	return normalizer.to_comments_list(
		raw,
		tostring(issue.key or ""),
		service.base_url(),
		issue.reporter and issue.reporter.id
	)
end

---@param issue Issue
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(conversation: IssueConversation|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_conversation(issue, opts, on_done)
	opts = opts or {}
	local issue_key = tostring(issue.key or "")
	if issue_key == "" then
		on_done(nil, "Invalid issue key")
		return nil
	end
	local cache_key = "jira:panel:comments:" .. issue_key

	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done({ comments = cached, activities = {} }, nil)
			return nil
		end
	end

	local endpoint = string.format("/issue/%s/comment?maxResults=100", issue_key)

	return service.request("GET", endpoint, nil, function(result, err)
		if err or not result then
			on_done(nil, err or "Failed to fetch comments")
			return
		end

		local comments = map_comments(result, issue)
		service.set_memory_cache(cache_key, comments)
		on_done({ comments = comments, activities = {} }, nil)
	end, {
		action = "Fetch comments",
		issue_key = issue_key,
	})
end

---@param issue Issue
---@param comment string
---@param comment_id string|nil
---@param parent_id string|number|nil
---@param callback fun(comment: IssueComment|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
local function write_comment(issue, comment, comment_id, parent_id, callback)
	local issue_key = tostring(issue.key or "")
	if vim.trim(comment) == "" then
		callback(nil, "Comment cannot be empty")
		return nil
	end

	local endpoint = string.format("/issue/%s/comment", issue_key)
	if comment_id then
		endpoint = endpoint .. "/" .. comment_id
	end
	local payload = { body = service.is_server() and comment or markdown.to_adf(comment) }
	if parent_id ~= nil and tostring(parent_id) ~= "" then
		payload.parentId = tostring(parent_id)
	end

	return service.request(comment_id and "PUT" or "POST", endpoint, payload, function(result, err)
		if err or not result then
			callback(nil, err or "Empty response")
			return
		end

		service.clear_memory_cache()
		local comments = map_comments({ comments = { result } }, issue)
		callback(comments[1], nil)
	end, {
		action = comment_id and "Edit comment" or "Add comment",
		issue_key = issue_key,
		comment_id = comment_id,
	})
end

---@param issue Issue
---@param content string
---@param opts { parent?: IssueComment }|nil
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.add_comment(issue, content, opts, on_done)
	local parent = opts and opts.parent
	return write_comment(issue, content, nil, parent and parent.id, on_done)
end

---@param issue Issue
---@param comment IssueComment
---@param content string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.edit_comment(issue, comment, content, on_done)
	return write_comment(issue, content, tostring(comment.id), nil, on_done)
end

---@param issue Issue
---@param comment IssueComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.delete_comment(issue, comment, on_done)
	local issue_key = tostring(issue.key or "")
	local id = tostring(comment.id)
	local endpoint = string.format("/issue/%s/comment/%s", issue_key, id)

	return service.request("DELETE", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.clear_memory_cache()
		on_done(true, nil)
	end, {
		action = "Delete comment",
		issue_key = issue_key,
		comment_id = id,
	})
end

return M
