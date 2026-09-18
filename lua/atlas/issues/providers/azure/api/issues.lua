local M = {}

local mapper = require("atlas.issues.providers.azure.api.mapper")
local markdown = require("atlas.issues.providers.azure.markdown")
local request_scope = require("atlas.core.requests")
local service = require("atlas.pulls.providers.azure.api.service")

---@param endpoint string
---@param opts IssuesFetchOpts
---@param on_done fun(result: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function get(endpoint, opts, on_done)
	local cache_key = "issues:" .. endpoint
	if not opts.force_refresh then
		local cached, found = service.get_cache(cache_key)
		if found then
			on_done(cached, nil)
			return nil
		end
	end
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		service.set_cache(cache_key, result)
		on_done(result, nil)
	end, { action = "Fetch work items" })
end

---@param ids integer[]
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[], err: string|nil)
---@return AtlasRequestScope
local function fetch_items(ids, opts, on_done)
	local scope = request_scope.new()
	local starts = {}
	for first = 1, #ids, 200 do
		local chunk = vim.list_slice(ids, first, math.min(first + 199, #ids))
		table.insert(starts, function(done)
			return get("/_apis/wit/workitems" .. service.build_query({ ids = table.concat(chunk, ",") }), opts, done)
		end)
	end
	scope.all(starts, function(results, errors)
		local by_id = {}
		for index = 1, #starts do
			if errors[index] then
				on_done({}, errors[index])
				return
			end
			for _, raw in ipairs(results[index].value) do
				by_id[raw.id] = mapper.to_issue(raw)
			end
		end
		local issues = {}
		for _, id in ipairs(ids) do
			table.insert(issues, by_id[id])
		end
		on_done(issues, nil)
	end)
	return scope
end

---@param view AtlasAzureIssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(result: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function query(view, opts, on_done)
	local endpoint = "/" .. service.url_encode(view.project) .. "/_apis/wit/wiql"
	local cache_key = "issues:query:" .. endpoint .. ":" .. view.search
	if not opts.force_refresh then
		local cached, found = service.get_cache(cache_key)
		if found then
			on_done(cached, nil)
			return nil
		end
	end
	return service.request("POST", endpoint, { query = view.search }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		if result.queryType ~= "flat" then
			on_done(nil, "Azure issue views require a flat WIQL query")
			return
		end
		service.set_cache(cache_key, result)
		on_done(result, nil)
	end, { action = "Query work items" })
end

---@param view AtlasAzureIssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(page: IssuesPage, err: string|nil)
---@return AtlasRequestScope
function M.list_issues(view, opts, on_done)
	local scope = request_scope.new()
	local offset = tonumber(opts.cursor) or 0
	local size = math.min(opts.pagelen or 50, 200)
	scope.run(function(done)
		return query(view, opts, done)
	end, function(result, err)
		if err then
			on_done({ items = {} }, err)
			return
		end
		local ids = {}
		for index = offset + 1, math.min(offset + size, #result.workItems) do
			table.insert(ids, result.workItems[index].id)
		end
		scope.run(function(done)
			return fetch_items(ids, opts, done)
		end, function(items, fetch_err)
			on_done({
				items = items,
				next_cursor = offset + size < #result.workItems and tostring(offset + size) or nil,
				total_pages = math.max(1, math.ceil(#result.workItems / size)),
			}, fetch_err)
		end)
	end)
	return scope
end

---@param refs IssueRef[]
---@param opts IssuesFetchOpts|nil
---@param on_done fun(issues: Issue[], err: string|nil)
---@return AtlasRequestScope|nil
function M.fetch_by_refs(refs, opts, on_done)
	local ids = {}
	for _, ref in ipairs(refs) do
		local id = tonumber(ref.key)
		if not id then
			on_done({}, "Invalid Azure work item key: " .. ref.key)
			return nil
		end
		table.insert(ids, id)
	end
	return fetch_items(ids, opts or {}, on_done)
end

---@param ref IssueRef
---@param opts IssuesFetchOpts|nil
---@param on_done fun(details: IssueDetails|nil, err: string|nil)
---@return AtlasRequestScope
function M.fetch_issue(ref, opts, on_done)
	local scope = request_scope.new()
	scope.run(function(done)
		return get("/_apis/wit/workitems/" .. service.url_encode(ref.key), opts or {}, done)
	end, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local details = mapper.to_issue_details(result)
		scope.run(function(done)
			return markdown.to_markdown(details.description, details.description_format, done)
		end, function(description, format)
			details.description = description
			details.description_format = format
			on_done(details, nil)
		end)
	end)
	return scope
end

---@param fields table<string, any>
---@return table[]
local function field_patch(fields)
	local patch = {}
	for field, value in pairs(fields) do
		table.insert(patch, { op = "add", path = "/fields/" .. field, value = value })
	end
	return patch
end

---@param issue Issue
---@param fields table<string, any>
---@param on_done fun(ok: boolean, err: string|nil)
---@param opts { format?: string }|nil
---@return { cancel: fun() }|nil
function M.update(issue, fields, on_done, opts)
	local patch = field_patch(fields)
	if fields["System.Description"] and opts and opts.format == "markdown" then
		-- Azure's HTML-to-Markdown format switch is permanent.
		table.insert(patch, { op = "add", path = "/multilineFieldsFormat/System.Description", value = "Markdown" })
	end
	return service.request("PATCH", "/_apis/wit/workitems/" .. issue.key, patch, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.clear_cache()
		on_done(true, nil)
	end, { action = "Update work item", issue_key = issue.key }, nil, "application/json-patch+json")
end

---@param issue Issue
---@param content string
---@param on_done fun(ok: boolean, err: string|nil)
---@param opts { format?: string }|nil
---@return { cancel: fun() }|nil
function M.update_description(issue, content, on_done, opts)
	return M.update(issue, { ["System.Description"] = content }, on_done, opts)
end

---@param issue Issue
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete(issue, on_done)
	return service.request("DELETE", "/_apis/wit/workitems/" .. issue.key, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.clear_cache()
		on_done(true, nil)
	end, { action = "Delete work item", issue_key = issue.key })
end

---@param project string
---@param item_type string
---@param fields table<string, any>
---@param on_done fun(issue: Issue|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create(project, item_type, fields, on_done)
	local endpoint =
		string.format("/%s/_apis/wit/workitems/$%s", service.url_encode(project), service.url_encode(item_type))
	local patch = field_patch(fields)
	if fields["System.Description"] then
		table.insert(patch, { op = "add", path = "/multilineFieldsFormat/System.Description", value = "Markdown" })
	end
	return service.request("POST", endpoint, patch, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		service.clear_cache()
		on_done(mapper.to_issue(result), nil)
	end, { action = "Create work item", project = project }, nil, "application/json-patch+json")
end

---@param issue Issue
---@param on_done fun(states: table[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_states(issue, on_done)
	---@cast issue AzureIssue
	local endpoint = string.format(
		"/%s/_apis/wit/workitemtypes/%s/states",
		service.url_encode(issue.project),
		service.url_encode(issue.type.name)
	)
	return get(endpoint, {}, function(result, err)
		on_done(result and result.value or nil, err)
	end)
end

---@param project string
---@param on_done fun(types: table[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_types(project, on_done)
	return get("/" .. service.url_encode(project) .. "/_apis/wit/workitemtypes", {}, function(result, err)
		on_done(result and result.value or nil, err)
	end)
end

return M
