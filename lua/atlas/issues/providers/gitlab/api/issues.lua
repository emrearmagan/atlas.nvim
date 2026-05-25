local M = {}

local service = require("atlas.issues.providers.gitlab.api.service")
local normalizer = require("atlas.issues.providers.gitlab.api.mapper")

---@param params table<string, any>
---@return string
local function build_query(params)
	local parts = {}
	for k, v in pairs(params or {}) do
		if v ~= nil and v ~= "" then
			table.insert(parts, k .. "=" .. service.url_encode(tostring(v)))
		end
	end
	if #parts == 0 then
		return ""
	end
	return "?" .. table.concat(parts, "&")
end

---@param view AtlasGitLabIssuesViewConfig
---@param opts { force_load?: boolean, max_results?: number }|nil
---@param on_done fun(issues: Issue[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_issues(view, opts, on_done)
	opts = opts or {}
	local params = {
		scope = view.scope or "assigned_to_me",
		state = view.state or "opened",
		per_page = tostring(opts.max_results or 50),
		order_by = view.order_by or "updated_at",
		sort = view.sort or "desc",
	}
	if view.labels then
		params.labels = view.labels
	end
	if view.milestone then
		params.milestone = view.milestone
	end
	if view.assignee_username then
		params.assignee_username = view.assignee_username
	end
	if view.author_username then
		params.author_username = view.author_username
	end
	if view.search and view.search ~= "" then
		params.search = view.search
	end
	if type(view.extra_params) == "table" then
		for k, v in pairs(view.extra_params) do
			params[k] = v
		end
	end

	local endpoint = "/issues" .. build_query(params)
	local cache_key = "gitlab:issues:list:" .. endpoint

	if not opts.force_load then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local issues = normalizer.to_issues_list(type(result) == "table" and result or {})
		service.set_memory_cache(cache_key, issues)
		on_done(issues, nil)
	end, {
		action = "List issues",
		endpoint = endpoint,
	})
end

---@param key string
---@param opts { force_load?: boolean }|nil
---@param on_done fun(issue: Issue|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_issue(key, opts, on_done)
	opts = opts or {}
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key: " .. tostring(key))
		return nil
	end

	local cache_key = string.format("gitlab:issue:%s#%d", path, iid)
	if not opts.force_load then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/projects/%s/issues/%d", service.url_encode(path), iid)
	return service.request("GET", endpoint, nil, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		local issue = normalizer.to_issue(result)
		if issue then
			service.set_memory_cache(cache_key, issue)
		end
		on_done(issue, nil)
	end, {
		action = "Fetch issue",
		path = path,
		iid = iid,
	})
end

---@param key string
---@param state_event "close"|"reopen"
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_state(key, state_event, on_done)
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(false, "Invalid issue key")
		return nil
	end
	local endpoint = string.format("/projects/%s/issues/%d", service.url_encode(path), iid)
	return service.request("PUT", endpoint, { state_event = state_event }, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.delete_memory_cache(string.format("gitlab:issue:%s#%d", path, iid))
		on_done(true, nil)
	end, {
		action = "Issue state change",
		path = path,
		iid = iid,
		state = state_event,
	})
end

---@param key string
---@param diff { add?: string[], remove?: string[] }
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_labels(key, diff, on_done)
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(false, "Invalid issue key")
		return nil
	end

	local payload = {}
	if type(diff.add) == "table" and #diff.add > 0 then
		payload.add_labels = table.concat(diff.add, ",")
	end
	if type(diff.remove) == "table" and #diff.remove > 0 then
		payload.remove_labels = table.concat(diff.remove, ",")
	end
	if next(payload) == nil then
		on_done(true, nil)
		return nil
	end

	local endpoint = string.format("/projects/%s/issues/%d", service.url_encode(path), iid)
	return service.request("PUT", endpoint, payload, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.delete_memory_cache(string.format("gitlab:issue:%s#%d", path, iid))
		on_done(true, nil)
	end, {
		action = "Update labels",
		path = path,
		iid = iid,
		add = diff.add,
		remove = diff.remove,
	})
end

---@param key string
---@param ids integer[]
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_assignee_ids(key, ids, on_done)
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(false, "Invalid issue key")
		return nil
	end

	local payload = { assignee_ids = ids }
	if #ids == 0 then
		-- Empty array unassigns; GitLab requires assignee_ids = [0] for clearing
		payload = { assignee_ids = { 0 } }
	end

	local endpoint = string.format("/projects/%s/issues/%d", service.url_encode(path), iid)
	return service.request("PUT", endpoint, payload, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.delete_memory_cache(string.format("gitlab:issue:%s#%d", path, iid))
		on_done(true, nil)
	end, {
		action = "Set assignees",
		path = path,
		iid = iid,
		ids = ids,
	})
end

---@class GitLabCreateIssueOpts
---@field project_path string  -- "group/project"
---@field title string
---@field description string|nil
---@field assignee_ids integer[]|nil
---@field labels string[]|nil  -- list of label names - joined with comma for the API
---@field milestone_id integer|nil
---@field due_date string|nil  -- "YYYY-MM-DD"
---@field confidential boolean|nil

---@class GitLabCreateIssueResult
---@field key string|nil  -- "group/project#iid"
---@field iid integer|nil
---@field url string|nil

---@param opts GitLabCreateIssueOpts
---@param on_done fun(result: GitLabCreateIssueResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_issue(opts, on_done)
	if type(opts) ~= "table" then
		on_done(nil, "Missing options")
		return nil
	end
	local path = tostring(opts.project_path or "")
	if path == "" then
		on_done(nil, "Missing project_path")
		return nil
	end
	local title = tostring(opts.title or "")
	if vim.trim(title) == "" then
		on_done(nil, "Title is required")
		return nil
	end

	local payload = { title = title }
	if type(opts.description) == "string" and opts.description ~= "" then
		payload.description = opts.description
	end
	if type(opts.assignee_ids) == "table" and #opts.assignee_ids > 0 then
		payload.assignee_ids = opts.assignee_ids
	end
	if type(opts.labels) == "table" and #opts.labels > 0 then
		payload.labels = table.concat(opts.labels, ",")
	end
	if type(opts.milestone_id) == "number" then
		payload.milestone_id = opts.milestone_id
	end
	if type(opts.due_date) == "string" and opts.due_date ~= "" then
		payload.due_date = opts.due_date
	end
	if opts.confidential == true then
		payload.confidential = true
	end

	local endpoint = string.format("/projects/%s/issues", service.url_encode(path))

	return service.request("POST", endpoint, payload, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end

		local issue = normalizer.to_issue(result)
		local iid = (issue and issue._raw and issue._raw.iid) or tonumber(result.iid)
		local key = (issue and issue.key) or (iid and string.format("%s#%d", path, iid) or nil)
		service.clear_memory_cache()

		on_done({
			key = key,
			iid = iid,
			url = (issue and issue.url) or (type(result.web_url) == "string" and result.web_url or nil),
		}, nil)
	end, {
		action = "Create issue",
		path = path,
		title = title,
	})
end

---@param key string
---@param opts { force_load?: boolean }|nil
---@param on_done fun(description: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_description(key, opts, on_done)
	return M.get_issue(key, opts, function(issue, err)
		if err or issue == nil then
			on_done(nil, err)
			return
		end
		local raw = type(issue._raw) == "table" and issue._raw or {}
		on_done(tostring(raw.description or ""), nil)
	end)
end

---@param query string
---@param opts { force_load?: boolean, max_results?: number }|nil
---@param on_done fun(items: { id: any, key: string, summary: string }[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.search_issues_picker(query, opts, on_done)
	opts = opts or {}
	local params = {
		scope = "all",
		state = "all",
		search = query,
		per_page = tostring(opts.max_results or 30),
		order_by = "updated_at",
		sort = "desc",
	}
	local endpoint = "/issues" .. build_query(params)

	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local issues = normalizer.to_issues_list(type(result) == "table" and result or {})
		local items = {}
		for _, issue in ipairs(issues) do
			table.insert(items, {
				id = issue.key,
				key = issue.key,
				summary = issue.summary,
			})
		end
		on_done(items, nil)
	end, {
		action = "Issue search picker",
		query = query,
	})
end

return M
