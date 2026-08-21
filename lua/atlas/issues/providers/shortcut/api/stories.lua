local M = {}

local json = require("atlas.core.json")
local mapper = require("atlas.issues.providers.shortcut.api.mapper")
local members = require("atlas.issues.providers.shortcut.api.members")
local requests = require("atlas.core.requests")
local service = require("atlas.issues.providers.shortcut.api.service")
local workflows = require("atlas.issues.providers.shortcut.api.workflows")

---@param story_id integer
local function invalidate(story_id)
	service.clear_cache("story:" .. tostring(story_id))
	service.clear_cache("search:")
end

---@param value number|nil
---@return integer
local function page_size(value)
	local number = math.floor(value or 50)
	return math.min(250, math.max(1, number))
end

---@param query string
---@param opts { max_results?: number }
---@return string
local function search_endpoint(query, opts)
	return string.format(
		"/search/stories?query=%s&page_size=%d&detail=slim",
		service.url_encode(query),
		page_size(opts.max_results)
	)
end

---@param query string
---@param opts? IssuesFetchOpts
---@param on_done fun(issues: ShortcutIssue[], next_page_token: string|nil, is_last: boolean, err: string|nil)
---@return AtlasRequestScope
function M.search(query, opts, on_done)
	opts = opts or {}
	local endpoint = search_endpoint(query, opts)
	local cache_key = "search:" .. endpoint
	local scope = requests.new()

	scope.all({
		users = function(done)
			return members.list(done)
		end,
		states = function(done)
			return workflows.list_states(done)
		end,
	}, function(values, errors)
		local lookup_err = errors.users or errors.states
		if lookup_err then
			on_done({}, nil, true, lookup_err)
			return
		end
		---@type IssueUser[]
		local users = values.users
		---@type ShortcutWorkflowState[]
		local states = values.states

		if not opts.force_load then
			local cached, found = service.get_cache(cache_key)
			if found then
				on_done(mapper.to_issues(cached.stories, users, states), nil, true, nil)
				return
			end
		end

		scope.run(function(done)
			return service.request("GET", endpoint, nil, done, { action = "Search Shortcut Stories" })
		end, function(result, err)
			if err then
				on_done({}, nil, true, err)
				return
			end
			---@cast result table

			local page = {
				stories = result.data,
			}
			service.set_cache(cache_key, page)
			on_done(mapper.to_issues(page.stories, users, states), nil, true, nil)
		end)
	end)
	return scope
end

---@param story_id integer
---@param opts IssuesFetchOpts
---@param on_done fun(story: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function get_story(story_id, opts, on_done)
	local cache_key = "story:" .. tostring(story_id)
	if not opts.force_load then
		local cached, found = service.get_memory_cache(cache_key)
		if found then
			on_done(cached, nil)
			return nil
		end
	end

	return service.request("GET", "/stories/" .. tostring(story_id), nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		service.set_memory_cache(cache_key, result)
		on_done(result, nil)
	end, { action = "Fetch Shortcut Story", issue_key = tostring(story_id) })
end

---@param story_id integer
---@param opts? IssuesFetchOpts
---@param on_done fun(issue: ShortcutIssueDetails|nil, err: string|nil)
---@return AtlasRequestScope
function M.get(story_id, opts, on_done)
	opts = opts or {}
	local scope = requests.new()
	scope.all({
		story = function(done)
			return get_story(story_id, opts, done)
		end,
		users = function(done)
			return members.list(done)
		end,
	}, function(values, errors)
		local err = errors.story or errors.users
		if err then
			on_done(nil, err)
			return
		end
		on_done(mapper.to_issue_details(values.story, values.users), nil)
	end)
	return scope
end

---@param refs IssueRef[]
---@param opts IssuesFetchOpts|nil
---@param on_done fun(issues: Issue[], err: string|nil)
---@return AtlasRequestScope|nil
function M.fetch_by_refs(refs, opts, on_done)
	if #refs == 0 then
		on_done({}, nil)
		return nil
	end
	if #refs > 1 then
		on_done({}, "Shortcut does not support bulk Story fetches")
		return nil
	end

	local story_id = tonumber(refs[1].key)
	if story_id == nil or story_id < 1 then
		on_done({}, "Invalid Shortcut Story key: " .. refs[1].key)
		return nil
	end

	opts = opts or {}
	return M.search("id:" .. tostring(story_id), {
		force_load = opts.force_load,
		max_results = 1,
	}, function(issues, _, _, err)
		on_done(issues, err)
	end)
end

---@param fields ShortcutStoryCreate
---@param on_done fun(story: ShortcutStoryCreated|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create(fields, on_done)
	return service.request("POST", "/stories", fields, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		---@cast result table
		service.clear_cache("search:")
		on_done({ id = result.id, key = tostring(result.id), url = json.safe_str(result.app_url) }, nil)
	end, { action = "Create Shortcut Story" })
end

---@param issue Issue
---@param fields ShortcutStoryUpdate
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update(issue, fields, on_done)
	---@cast issue ShortcutIssue
	return service.request("PUT", "/stories/" .. tostring(issue.id), fields, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		invalidate(issue.id)
		on_done(true, nil)
	end, { action = "Update Shortcut Story", issue_key = issue.key })
end

---@param issue Issue
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete(issue, on_done)
	---@cast issue ShortcutIssue
	return service.request("DELETE", "/stories/" .. tostring(issue.id), nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		invalidate(issue.id)
		on_done(true, nil)
	end, { action = "Delete Shortcut Story", issue_key = issue.key })
end

return M
