local M = {}

local service = require("atlas.providers.jira.client")
local normalizer = require("atlas.issues.providers.jira.api.mapper")
local markdown = require("atlas.formats.adf.from_markdown")

---@param raw table
---@param issue_key string
---@return IssueComment[]
local function map_comments(raw, issue_key)
	return normalizer.to_comments_list(raw, {
		issue_key = issue_key,
		base_url = service.base_url(),
	})
end

---@param issue_key string
---@param callback fun(comments: IssueComment[]|nil, err: string|nil)
---@param opts { force_refresh?: boolean }|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.get_comments(issue_key, callback, opts)
	opts = opts or {}
	local cache_key = "jira:panel:comments:" .. issue_key

	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			callback(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/issue/%s/comment?maxResults=100", issue_key)

	return service.request("GET", endpoint, nil, function(result, err)
		if err or not result then
			callback(nil, err or "Empty response")
			return
		end

		local comments = map_comments(result, issue_key)
		service.set_memory_cache(cache_key, comments)
		callback(comments, nil)
	end, {
		action = "Fetch comments",
		issue_key = issue_key,
	})
end

---@param issue_key string
---@param comment string
---@param comment_id string|nil
---@param parent_id string|number|nil
---@param callback fun(comment: IssueComment|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
local function write_comment(issue_key, comment, comment_id, parent_id, callback)
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
		local comments = map_comments({ comments = { result } }, issue_key)
		callback(comments[1], nil)
	end, {
		action = comment_id and "Edit comment" or "Add comment",
		issue_key = issue_key,
		comment_id = comment_id,
	})
end

---@param issue_key string
---@param comment string
---@param opts { parent_id?: string|number }|nil
---@param callback fun(comment: IssueComment|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.add_comment(issue_key, comment, opts, callback)
	return write_comment(issue_key, comment, nil, opts and opts.parent_id or nil, callback)
end

---@param issue_key string
---@param comment_id string|number
---@param comment string
---@param callback fun(comment: IssueComment|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.edit_comment(issue_key, comment_id, comment, callback)
	local id = tostring(comment_id or "")
	if id == "" then
		callback(nil, "Missing comment id")
		return nil
	end
	return write_comment(issue_key, comment, id, nil, callback)
end

---@param issue_key string
---@param comment_id string|number
---@param callback fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.delete_comment(issue_key, comment_id, callback)
	local id = tostring(comment_id or "")
	if id == "" then
		callback(false, "Missing comment id")
		return nil
	end

	local endpoint = string.format("/issue/%s/comment/%s", issue_key, id)

	return service.request("DELETE", endpoint, nil, function(_, err)
		if err then
			callback(false, err)
			return
		end
		service.clear_memory_cache()
		callback(true, nil)
	end, {
		action = "Delete comment",
		issue_key = issue_key,
		comment_id = id,
	})
end

return M
