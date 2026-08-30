local M = {}

local service = require("atlas.issues.providers.jira.api.service")
local normalizer = require("atlas.issues.providers.jira.api.mapper")
local json = require("atlas.core.json")
local config = require("atlas.config")
local url_encode = require("atlas.core.utils").url_encode

local function project_config()
	return (config.domain_options("jira", "issues") or {}).project_config or {}
end

local function story_points_field()
	return tostring(project_config().story_points_field or "customfield_10016")
end

local function search_fields()
	return {
		"summary",
		"status",
		"project",
		"assignee",
		"reporter",
		"parent",
		"priority",
		"issuetype",
		"duedate",
		"watches",
		"created",
		"updated",
		"resolutiondate",
		story_points_field(),
	}
end

---@param fields_config AtlasJiraProjectFieldsConfig
---@return string[]
local function custom_field_ids(fields_config)
	local ids = {}
	for field_id in pairs(fields_config) do
		table.insert(ids, field_id)
	end
	table.sort(ids)
	return ids
end

---@param extra_fields string[]
---@return string[]
local function detail_fields(extra_fields)
	local fields = { "description", "labels" }
	vim.list_extend(fields, extra_fields)
	return fields
end

---@param data table
---@param on_done fun(result: table|nil, err: string|nil)
---@param ctx table|nil
---@return { job_id: integer, cancel: fun() }|nil
local function search_jql_request(data, on_done, ctx)
	if service.is_server() then
		local payload = vim.deepcopy(data)
		payload.startAt = tonumber(payload.nextPageToken) or 0
		payload.nextPageToken = nil

		return service.request("POST", "/search", payload, function(result, err)
			if result then
				local start_at = tonumber(result.startAt) or 0
				local max_results = tonumber(result.maxResults) or #(result.issues or {})
				local total = tonumber(result.total) or 0
				local next_start = start_at + max_results
				result.isLast = next_start >= total
				result.nextPageToken = result.isLast and nil or tostring(next_start)
			end
			on_done(result, err)
		end, ctx)
	else
		return service.request("POST", "/search/jql", data, on_done, ctx)
	end
end

---@class JiraIssueSearchPage
---@field issues Issue[]
---@field nextPageToken string|nil
---@field isLast boolean

---@param jql string
---@param on_done fun(page: JiraIssueSearchPage|nil, err: string|nil)
---@param opts { force_load?: boolean, next_page_token?: string|nil, max_results?: number|nil }|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.search_issues(jql, on_done, opts)
	opts = opts or {}
	local page_token = opts.next_page_token or ""
	local page_size = math.max(1, tonumber(opts.max_results) or 50)
	local cache_key = "jira:search:v2:" .. jql .. ":page:" .. page_token .. ":size:" .. tostring(page_size)

	if not opts.force_load then
		local cached = service.get_cache(cache_key)
		if cached then
			on_done(cached, nil)
			return nil
		end
	end

	local data = {
		jql = jql,
		fields = search_fields(),
		nextPageToken = page_token,
		maxResults = page_size,
	}

	return search_jql_request(data, function(result, err)
		if err or not result then
			on_done(nil, err or "Empty response")
			return
		end

		local page = {
			issues = normalizer.to_issues_list(result.issues or {}, story_points_field()),
			nextPageToken = result.nextPageToken,
			isLast = result.isLast == true,
		}

		service.set_cache(cache_key, page)
		on_done(page, nil)
	end, {
		action = "Search issues",
		jql = jql,
	})
end

---@class JiraIssuePickerItem
---@field id string
---@field key string
---@field title string

---@param query string
---@param on_done fun(items: JiraIssuePickerItem[]|nil, err: string|nil)
---@param opts { force_load?: boolean }|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.search_issue(query, on_done, opts)
	opts = opts or {}
	local q = vim.trim(tostring(query or ""))

	local cache_key = "jira:issue_picker:" .. q
	if not opts.force_load then
		local cached_items, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached_items, nil)
			return nil
		end
	end

	local endpoint = "/issue/picker?query="
		.. url_encode(q)
		.. "&currentJQL="
		.. url_encode("ORDER BY updated DESC")
		.. "&showSubTasks=true&showSubTaskParent=true"

	return service.request("GET", endpoint, nil, function(result, err)
		if err ~= nil then
			on_done(nil, err or "Empty response")
			return
		end

		---@type JiraIssuePickerItem[]
		local items = {}
		for _, section in ipairs(result.sections or {}) do
			for _, issue in ipairs(section.issues or {}) do
				local key = tostring(issue.key or "")
				if key ~= "" then
					local title = tostring(issue.summaryText or issue.summary or "")
					table.insert(items, {
						id = tostring(issue.id or key),
						key = key,
						title = title,
					})
				end
			end
		end

		service.set_memory_cache(cache_key, items)
		on_done(items, nil)
	end, {
		action = "Issue picker search",
		query = q,
	})
end

---@param ref IssueRef
---@param opts IssuesFetchOpts|nil
---@param callback fun(details: IssueDetails|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.fetch_issue(ref, opts, callback)
	local issue_key = tostring(ref.key or "")
	if issue_key == "" then
		callback(nil, "Missing issue key")
		return nil
	end
	opts = opts or {}
	local cache_key = "jira:issue-details:" .. issue_key
	if not opts.force_load then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			callback(cached, nil)
			return nil
		end
	end

	local project_key = issue_key:match("^([^-]+)-")
	local configured = project_config()[project_key] or {}
	local extra_fields = custom_field_ids(configured)
	local endpoint = string.format("/issue/%s?fields=%s", issue_key, table.concat(detail_fields(extra_fields), ","))

	return service.request("GET", endpoint, nil, function(result, err)
		if err or not result then
			callback(nil, err or "Empty response")
			return
		end

		local details = normalizer.to_issue_details(result, configured)
		service.set_memory_cache(cache_key, details)
		callback(details, nil)
	end, {
		action = "Fetch issue",
		issue_key = issue_key,
	})
end

---@param issue_key string
---@param start_at number|nil
---@param max_results number|nil
---@param on_done fun(page: { values: IssueActivityEntry[], total: number, is_last: boolean }|nil, err: string|nil)
---@param opts { force_load?: boolean }|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.get_issue_history_page(issue_key, start_at, max_results, on_done, opts)
	if issue_key == "" then
		on_done(nil, "Missing issue key")
		return nil
	end

	opts = opts or {}
	local start = math.max(0, tonumber(start_at) or 0)
	local size = math.max(1, tonumber(max_results) or 100)
	local cache_key = string.format("jira:panel:history:%s:start:%d:size:%d", issue_key, start, size)

	if not opts.force_load then
		local cached_page, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached_page, nil)
			return nil
		end
	end

	local is_server = service.is_server()

	local endpoint
	if is_server then
		endpoint = string.format("/issue/%s?expand=changelog", issue_key)
	else
		endpoint = string.format("/issue/%s/changelog?startAt=%d&maxResults=%d", issue_key, start, size)
	end

	return service.request("GET", endpoint, nil, function(result, err)
		if err or not result then
			on_done(nil, err or "Empty response")
			return
		end

		local raw = result
		if is_server then
			raw = json.safe_table(result.changelog)
		end

		local page = normalizer.to_history_page(raw, start, size)
		service.set_memory_cache(cache_key, page)
		on_done(page, nil)
	end, {
		action = "Fetch issue history page",
		issue_key = issue_key,
		start_at = start,
		max_results = size,
	})
end

---@param fields table
---@param callback fun(result: table|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.create_issue(fields, callback)
	if not fields.summary or fields.summary == "" then
		callback(nil, "Missing summary")
		return nil
	end

	if not fields.project then
		callback(nil, "Missing project")
		return nil
	end

	if not fields.issuetype then
		callback(nil, "Missing issue type")
		return nil
	end

	local payload = { fields = fields }

	return service.request("POST", "/issue", payload, function(result, err)
		if err ~= nil then
			callback(nil, err)
			return
		end

		if not result or not result.key then
			callback(nil, "Invalid response")
			return
		end

		callback({
			key = result.key,
			id = result.id,
			self = result.self,
		}, nil)
	end, {
		action = "Create issue",
		summary = fields.summary,
	})
end

---@param issue_key string
---@param fields table
---@param callback fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.update_issue(issue_key, fields, callback)
	if issue_key == "" then
		callback(false, "Missing issue key")
		return nil
	end

	local endpoint = string.format("/issue/%s", issue_key)
	local payload = { fields = fields }

	return service.request("PUT", endpoint, payload, function(_, err)
		if err ~= nil then
			callback(false, err)
			return
		end

		callback(true, nil)
	end, {
		action = "Update issue",
		issue_key = issue_key,
	})
end

---@param issue_key string
---@param callback fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.delete_issue(issue_key, callback)
	if issue_key == "" then
		callback(false, "Missing issue key")
		return nil
	end

	local endpoint = string.format("/issue/%s", issue_key)

	return service.request("DELETE", endpoint, nil, function(_, err)
		if err ~= nil then
			callback(false, err)
			return
		end

		callback(true, nil)
	end, {
		action = "Delete issue",
		issue_key = issue_key,
	})
end

---@param project_key string
---@param callback fun(issue_types: IssueType[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.get_create_meta(project_key, callback)
	if project_key == "" then
		callback(nil, "Missing project key")
		return nil
	end

	local escaped_key = url_encode(project_key)

	if service.is_server() then
		local endpoint = string.format("/issue/createmeta/%s/issuetypes", escaped_key)
		return service.request("GET", endpoint, nil, function(result, err)
			if err ~= nil then
				callback(nil, err or "Empty response")
				return
			end

			local raw_types = result.values or {}
			local issue_types = {}
			for _, raw in ipairs(raw_types) do
				local issue_type = normalizer.to_issue_type(raw)
				if issue_type ~= nil then
					table.insert(issue_types, issue_type)
				end
			end
			callback(issue_types, nil)
		end, {
			action = "Fetch create metadata",
			project_key = project_key,
		})
	end

	local endpoint = string.format("/issue/createmeta?projectKeys=%s&expand=projects.issuetypes", escaped_key)

	return service.request("GET", endpoint, nil, function(result, err)
		if err ~= nil then
			callback(nil, err or "Empty response")
			return
		end

		local projects = json.safe_table(result.projects)

		local matched_project = nil
		for _, project in ipairs(projects) do
			if tostring(project.key or "") == project_key then
				matched_project = project
				break
			end
		end

		local project = matched_project or projects[1]
		local raw_types = json.safe_table(project and project.issuetypes)

		local issue_types = {}
		for _, raw in ipairs(raw_types) do
			local issue_type = normalizer.to_issue_type(raw)
			if issue_type ~= nil then
				table.insert(issue_types, issue_type)
			end
		end

		callback(issue_types, nil)
	end, {
		action = "Fetch create metadata",
		project_key = project_key,
	})
end

return M
