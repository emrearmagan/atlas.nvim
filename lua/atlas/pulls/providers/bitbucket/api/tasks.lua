local M = {}

local mapper = require("atlas.pulls.providers.bitbucket.api.mapper")
local service = require("atlas.pulls.providers.bitbucket.api.service")

---@param pr PullRequest
---@return string
local function endpoint(pr)
	return string.format(
		"/repositories/%s/%s/pullrequests/%s/tasks",
		tostring(pr.workspace or ""),
		tostring(pr.repo or ""),
		tostring(pr.id or "")
	)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(tasks: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_tasks(pr, opts, on_done)
	local fields = table.concat({
		"values.id",
		"values.comment.id",
		"values.creator.display_name",
		"values.creator.nickname",
		"values.creator.username",
		"values.creator.account_id",
		"values.content.raw",
		"values.created_on",
		"values.resolved_on",
		"values.resolved_by.display_name",
		"values.resolved_by.nickname",
		"values.resolved_by.username",
		"values.resolved_by.account_id",
		"values.pending",
		"values.state",
		"values.links.self.href",
		"values.links.html.href",
		"next",
	}, ",")
	local url = string.format("%s?pagelen=100&fields=%s", endpoint(pr), fields)
	local key = string.format(
		"bitbucket:pr:tasks:%s/%s/%s",
		tostring(pr.workspace or ""),
		tostring(pr.repo or ""),
		tostring(pr.id or "")
	)
	if not (opts or {}).force_refresh then
		local cached, ok = service.get_cache(key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.fetch_all_values(url, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local tasks = mapper.to_tasks_list(result)
		table.sort(tasks, function(a, b)
			return tostring(a.created_on or "") < tostring(b.created_on or "")
		end)
		service.set_cache(key, tasks, service.cache_ttl())
		on_done(tasks, nil)
	end)
end

---@param pr PullRequest
---@param content string
---@param parent PullsComment|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_task(pr, content, parent, on_done)
	local payload = {
		content = { raw = content },
	}
	if parent then
		payload.comment = { id = tonumber(parent.id) or parent.id }
		if parent.state == "PENDING" then
			payload.pending = true
		end
	end

	return service.request("POST", endpoint(pr), nil, vim.json.encode(payload), function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		service.clear_cache()
		local task = mapper.to_tasks_list({ values = { result } })[1]
		if not task then
			on_done(nil, "Bitbucket did not return the created task")
			return
		end
		on_done(task, nil)
	end)
end

---@param task PullsComment
---@param on_done fun(task: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_task(task, on_done)
	local url = tostring(task.url or "")
	if url == "" then
		on_done(nil, "Missing task URL")
		return nil
	end

	local payload = { state = task.state == "RESOLVED" and "RESOLVED" or "UNRESOLVED" }
	if task.content_raw and task.content_raw ~= "" then
		payload.content = { raw = task.content_raw }
	end
	return service.request("PUT", url, nil, vim.json.encode(payload), function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		service.clear_cache()
		local updated = mapper.to_tasks_list({ values = { result } })[1]
		if not updated then
			on_done(nil, "Bitbucket did not return the updated task")
			return
		end
		on_done(updated, nil)
	end)
end

---@param task PullsComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_task(task, on_done)
	local url = tostring(task.url or "")
	if url == "" then
		on_done(false, "Missing task URL")
		return nil
	end

	return service.request("DELETE", url, nil, nil, function(_, err)
		if not err then
			service.clear_cache()
		end
		on_done(err == nil, err)
	end)
end

return M
