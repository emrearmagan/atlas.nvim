local M = {}

local service = require("atlas.issues.providers.jira.api.service")
local normalizer = require("atlas.issues.providers.jira.api.mapper")
local cache = require("atlas.core.cache")
local logger = require("atlas.core.logger")
local config = require("atlas.issues.providers.jira.api.config")

local CACHE_TTL = 300

local function story_points_field()
	local project_config = config.jira_config().project_config or {}
	return tostring(project_config.story_points_field or "customfield_10016")
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
		story_points_field(),
	}
end

---@param str string
---@return string
local function url_encode(str)
	return (str:gsub("([^%w%-_.~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

---@param data table
---@param on_done fun(result: table|nil, err: string|nil)
---@param ctx table|nil
---@return { job_id: integer, cancel: fun() }|nil
local function search_jql_request(data, on_done, ctx)
	if config.jira_config().api_type == "server" then
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
		return service.request("POST", "/search/jql", data, function(result, err)
			on_done(result, err)
		end, ctx)
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
	local ttl = service.cache_ttl()
	local page_token = opts.next_page_token or ""
	local page_size = math.max(1, tonumber(opts.max_results) or 50)
	local cache_key = "jira:search:" .. jql .. ":page:" .. page_token .. ":size:" .. tostring(page_size)

	if not opts.force_load then
		local cached = cache.get(cache_key)
		if cached and cached.value then
			logger.loginfo("Jira search cache hit", { jql = jql })
			on_done(cached.value, nil)
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

		cache.set(cache_key, page, ttl)
		logger.loginfo("Jira search page complete", {
			jql = jql,
			count = #page.issues,
			is_last = page.isLast,
		})
		on_done(page, nil)
	end, {
		action = "Search issues",
		jql = jql,
	})
end

---@class JiraIssuePickerItem
---@field id string
---@field key string
---@field summary string

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

	local endpoint = "/issue/picker?query=" .. url_encode(q) .. "&showSubTasks=true&showSubTaskParent=true"

	return service.request("GET", endpoint, nil, function(result, err)
		if err ~= nil or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end

		---@type JiraIssuePickerItem[]
		local items = {}
		for _, section in ipairs(result.sections or {}) do
			for _, issue in ipairs((type(section) == "table" and section.issues) or {}) do
				if type(issue) == "table" then
					local key = tostring(issue.key or "")
					if key ~= "" then
						local summary = tostring(issue.summaryText or issue.summary or "")
						table.insert(items, {
							id = tostring(issue.id or key),
							key = key,
							summary = summary,
						})
					end
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

---@param issue_key string
---@param callback fun(issue: Issue|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.get_issue(issue_key, callback)
	if type(issue_key) ~= "string" or issue_key == "" then
		callback(nil, "Missing issue key")
		return nil
	end

	local endpoint = string.format("/issue/%s?fields=%s", issue_key, table.concat(search_fields(), ","))

	return service.request("GET", endpoint, nil, function(result, err)
		if err or not result then
			callback(nil, err or "Empty response")
			return
		end

		callback(normalizer.to_issue(result, story_points_field()), nil)
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
	if type(issue_key) ~= "string" or issue_key == "" then
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

	local is_server = config.jira_config().api_type == "server"

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
			raw = type(result.changelog) == "table" and result.changelog or { values = {} }
			if raw.values == nil and raw.histories ~= nil then
				raw.values = raw.histories
			end
		end

		local page = normalizer.to_history_page(raw, start, size)
		service.set_memory_cache(cache_key, page, CACHE_TTL)
		on_done(page, nil)
	end, {
		action = "Fetch issue history page",
		issue_key = issue_key,
		start_at = start,
		max_results = size,
	})
end

---@class JiraIssueDetailResult
---@field description any
---@field custom_fields table<string, any>|nil

---@param issue_key string
---@param on_done fun(detail: JiraIssueDetailResult|nil, err: string|nil)
---@param opts { extra_fields?: string[], force_load?: boolean }|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.get_issue_detail(issue_key, on_done, opts)
	if type(issue_key) ~= "string" or issue_key == "" then
		on_done(nil, "Missing issue key")
		return nil
	end

	opts = opts or {}
	local fields = { "description" }
	local extra = opts.extra_fields or {}
	for _, f in ipairs(extra) do
		table.insert(fields, f)
	end

	local fields_suffix = "description"
	if #extra > 0 then
		local sorted_extra = vim.deepcopy(extra)
		table.sort(sorted_extra)
		fields_suffix = "description+" .. table.concat(sorted_extra, ",")
	end

	local cache_key = string.format("jira:panel:detail:%s:fields:%s", issue_key, fields_suffix)
	if not opts.force_load then
		local cached_detail, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached_detail, nil)
			return nil
		end
	end

	local data = {
		jql = "key = " .. issue_key,
		fields = fields,
		maxResults = 1,
	}

	return search_jql_request(data, function(result, err)
		if err or not result then
			logger.logerror("Jira detail fetch failed", {
				issue_key = issue_key,
				error = err or "Empty response",
			})
			on_done(nil, err or "Empty response")
			return
		end

		local first_issue = (result.issues or {})[1]
		local raw_fields = first_issue and first_issue.fields or {}

		local custom_fields = nil
		if #extra > 0 then
			custom_fields = {}
			for _, field_id in ipairs(extra) do
				custom_fields[field_id] = raw_fields[field_id]
			end
		end

		logger.loginfo("Jira detail fetch complete", {
			issue_key = issue_key,
			has_description = raw_fields.description ~= nil,
			custom_field_count = custom_fields and #extra or 0,
		})

		local detail = {
			description = raw_fields.description,
			custom_fields = custom_fields,
		}

		service.set_memory_cache(cache_key, detail, CACHE_TTL)
		on_done(detail, nil)
	end, {
		action = "Fetch issue detail",
		issue_key = issue_key,
		fields = fields,
	})
end

---@param issue_key string
---@param fields string[]
---@param on_done fun(values: table<string, any>|nil, err: string|nil)
---@param opts { force_load?: boolean }|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.get_custom_fields(issue_key, fields, on_done, opts)
	if type(issue_key) ~= "string" or issue_key == "" then
		on_done(nil, "Missing issue key")
		return nil
	end

	if #fields == 0 then
		on_done({}, nil)
		return nil
	end

	opts = opts or {}
	local sorted = vim.deepcopy(fields)
	table.sort(sorted)
	local cache_key = string.format("jira:panel:custom_fields:%s:%s", issue_key, table.concat(sorted, ","))

	if not opts.force_load then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local data = {
		jql = "key = " .. issue_key,
		fields = fields,
		maxResults = 1,
	}

	return search_jql_request(data, function(result, err)
		if err or not result then
			on_done(nil, err or "Empty response")
			return
		end

		local raw_fields = ((result.issues or {})[1] or {}).fields or {}
		local values = {}
		for _, field_id in ipairs(fields) do
			values[field_id] = raw_fields[field_id]
		end

		service.set_memory_cache(cache_key, values, CACHE_TTL)
		on_done(values, nil)
	end, {
		action = "Fetch custom fields",
		issue_key = issue_key,
		fields = fields,
	})
end

---@param issue_key string
---@param on_done fun(description: any, err: string|nil)
---@param opts { force_load?: boolean }|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.get_issue_description(issue_key, on_done, opts)
	return M.get_issue_detail(issue_key, function(detail, err)
		if err or not detail then
			on_done(nil, err)
			return
		end
		on_done(detail.description, nil)
	end, opts)
end

function M.create_issue(fields, callback)
	if type(callback) ~= "function" then
		return nil
	end

	if type(fields) ~= "table" then
		callback(nil, "Missing fields")
		return nil
	end

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
	if type(callback) ~= "function" then
		return nil
	end

	if type(issue_key) ~= "string" or issue_key == "" then
		callback(false, "Missing issue key")
		return nil
	end

	if type(fields) ~= "table" then
		callback(false, "Missing fields")
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
	if type(callback) ~= "function" then
		return nil
	end

	if type(issue_key) ~= "string" or issue_key == "" then
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
	if type(project_key) ~= "string" or project_key == "" then
		callback(nil, "Missing project key")
		return nil
	end

	local escaped_key = vim.fn.escape(project_key, "&=?")

	if config.jira_config().api_type == "server" then
		local endpoint = string.format("/issue/createmeta/%s/issuetypes", escaped_key)
		return service.request("GET", endpoint, nil, function(result, err)
			if err ~= nil or type(result) ~= "table" then
				callback(nil, err or "Empty response")
				return
			end

			local raw_types = type(result.values) == "table" and result.values or {}
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
		if err ~= nil or type(result) ~= "table" then
			callback(nil, err or "Empty response")
			return
		end

		local projects = result.projects
		if type(projects) ~= "table" then
			callback({}, nil)
			return
		end

		local matched_project = nil
		for _, project in ipairs(projects) do
			if type(project) == "table" and tostring(project.key or "") == project_key then
				matched_project = project
				break
			end
		end

		local project = matched_project or projects[1]
		local raw_types = type(project) == "table" and project.issuetypes or nil
		if type(raw_types) ~= "table" then
			callback({}, nil)
			return
		end

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
