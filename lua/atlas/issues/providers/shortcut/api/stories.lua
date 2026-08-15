local M = {}

local json = require("atlas.core.json")
local mapper = require("atlas.issues.providers.shortcut.api.mapper")
local members = require("atlas.issues.providers.shortcut.api.members")
local requests = require("atlas.core.requests")
local service = require("atlas.issues.providers.shortcut.api.service")

---@param value number|nil
---@return integer
local function page_size(value)
	local number = math.floor(value or 50)
	return math.min(250, math.max(1, number))
end

---@param query string
---@param opts { next_page_token?: string, max_results?: number }
---@return string
local function search_endpoint(query, opts)
	if opts.next_page_token then
		return (opts.next_page_token:gsub("^/api/v3", "", 1))
	end
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

	scope.run(function(done)
		return members.list(done)
	end, function(users, users_err)
		if users_err then
			on_done({}, nil, true, users_err)
			return
		end

		if not opts.force_load then
			local cached, found = service.get_cache(cache_key)
			if found then
				on_done(mapper.to_issues(cached.stories, users), cached.next_page_token, cached.is_last, nil)
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

			local next_page_token = json.safe_str(result.next)
			if next_page_token == "" then
				next_page_token = nil
			end
			local page = {
				stories = result.data,
				next_page_token = next_page_token,
				is_last = next_page_token == nil,
			}
			service.set_cache(cache_key, page)
			on_done(mapper.to_issues(page.stories, users), page.next_page_token, page.is_last, nil)
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
---@param opts IssuesFetchOpts|nil
---@param on_done fun(story: table|nil, users: IssueUser[]|nil, err: string|nil)
---@return AtlasRequestScope
local function load_story(story_id, opts, on_done)
	opts = opts or {}
	local scope = requests.new()
	scope.run(function(done)
		return members.list(done)
	end, function(users, users_err)
		if users_err then
			on_done(nil, nil, users_err)
			return
		end

		scope.run(function(done)
			return get_story(story_id, opts, done)
		end, function(story, story_err)
			if story_err then
				on_done(nil, nil, story_err)
				return
			end
			on_done(story, users, nil)
		end)
	end)
	return scope
end

---@param story_id integer
---@param opts? IssuesFetchOpts
---@param on_done fun(issue: ShortcutIssueDetails|nil, err: string|nil)
---@return AtlasRequestScope
function M.get(story_id, opts, on_done)
	return load_story(story_id, opts, function(story, users, err)
		if err then
			on_done(nil, err)
			return
		end
		---@cast story table
		---@cast users IssueUser[]
		on_done(mapper.to_issue_details(story, users), nil)
	end)
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

return M
