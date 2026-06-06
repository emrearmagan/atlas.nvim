local M = {}

local service = require("atlas.issues.providers.jira.api.service")
local normalizer = require("atlas.issues.providers.jira.api.mapper")
local markdown = require("atlas.issues.providers.jira.converted.markdown")
local config = require("atlas.issues.providers.jira.api.config")

local PANEL_CACHE_TTL = 300

---@param issue_key string
---@param start_at number|nil
---@param max_results number|nil
---@param callback fun(comments: IssueComment[]|nil, err: string|nil)
---@param opts { force_load?: boolean }|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.get_comments_page(issue_key, start_at, max_results, callback, opts)
	opts = opts or {}
	local start = tonumber(start_at) or 0
	local size = tonumber(max_results) or 100
	local cache_key = string.format("jira:panel:comments:%s:start:%d:size:%d", issue_key, start, size)

	if not opts.force_load then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			callback(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/issue/%s/comment?startAt=%d&maxResults=%d", issue_key, start, size)

	return service.request("GET", endpoint, nil, function(result, err)
		if err or not result then
			callback(nil, err or "Empty response")
			return
		end

		local comments = normalizer.to_comments_list(result, issue_key)
		service.set_memory_cache(cache_key, comments, PANEL_CACHE_TTL)
		callback(comments, nil)
	end, {
		action = "Fetch comments page",
		issue_key = issue_key,
		start_at = start,
		max_results = size,
	})
end

---@param issue_key string
---@param comment string
---@param opts { parent_id?: string|number }|fun(comment: IssueComment|nil, err: string|nil)|nil
---@param callback fun(comment: IssueComment|nil, err: string|nil)|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.add_comment(issue_key, comment, opts, callback)
	if type(opts) == "function" then
		callback = opts
		opts = nil
	end

	if type(callback) ~= "function" then
		return nil
	end

	local body = type(comment) == "string" and comment or ""
	if vim.trim(body) == "" then
		callback(nil, "Comment cannot be empty")
		return nil
	end

	local endpoint = string.format("/issue/%s/comment", issue_key)
	local payload = { body = "" }
	if config.jira_config().api_type == "cloud" then
		payload.body = markdown.to_adf(body)
	else
		payload.body = body
	end

	local parent_id = opts and opts.parent_id or nil
	if parent_id ~= nil then
		local pid = tostring(parent_id)
		if pid ~= "" then
			payload.parentId = pid
		end
	end

	return service.request("POST", endpoint, payload, function(result, err)
		if err or not result then
			callback(nil, err or "Empty response")
			return
		end

		service.clear_memory_cache()
		local comments = normalizer.to_comments_list({ comments = { result } }, issue_key)
		callback(comments[1], nil)
	end, {
		action = "Add comment",
		issue_key = issue_key,
	})
end

---@param issue_key string
---@param comment_id string|number
---@param comment string
---@param callback fun(comment: IssueComment|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.edit_comment(issue_key, comment_id, comment, callback)
	if type(callback) ~= "function" then
		return nil
	end

	local id = tostring(comment_id or "")
	if id == "" then
		callback(nil, "Missing comment id")
		return nil
	end

	local body = type(comment) == "string" and comment or ""
	if vim.trim(body) == "" then
		callback(nil, "Comment cannot be empty")
		return nil
	end

	local endpoint = string.format("/issue/%s/comment/%s", issue_key, id)
	local payload = { body = "" }
	if config.jira_config().api_type == "cloud" then
		payload.body = markdown.to_adf(body)
	else
		payload.body = body
	end

	return service.request("PUT", endpoint, payload, function(result, err)
		if err or not result then
			callback(nil, err or "Empty response")
			return
		end

		service.clear_memory_cache()
		local comments = normalizer.to_comments_list({ comments = { result } }, issue_key)
		callback(comments[1], nil)
	end, {
		action = "Edit comment",
		issue_key = issue_key,
		comment_id = id,
	})
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
