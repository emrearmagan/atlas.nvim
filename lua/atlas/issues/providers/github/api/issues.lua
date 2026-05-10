local M = {}

local cli = require("atlas.issues.providers.github.api.cli")
local normalizer = require("atlas.issues.providers.github.api.normalizer")
local logger = require("atlas.core.logger")

local DETAIL_JSON_FIELDS =
	"number,title,state,author,assignees,labels,createdAt,updatedAt,closedAt,url,body,comments,milestone,reactionGroups"

local SEARCH_GQL = [[
query($search: String!, $limit: Int!) {
  search(query: $search, type: ISSUE, first: $limit) {
    nodes {
      ... on Issue {
        number title state
        createdAt updatedAt closedAt url body
        repository { nameWithOwner }
        author { login ... on User { name } }
        assignees(first: 10) { nodes { login name } }
        labels(first: 20) { nodes { name color } }
        comments { totalCount }
      }
    }
  }
}
]]

---@param query string
---@return string
local function issue_search_query(query)
	if not query:lower():find("is:issue", 1, true) then
		query = query .. " is:issue"
	end
	return query
end

---@param search string
---@param on_done fun(issues: Issue[]|nil, err: string|nil)
---@param opts { force_load?: boolean, limit?: number }|nil
---@return { cancel: fun() }|nil
function M.search_issues(search, on_done, opts)
	opts = opts or {}
	local limit = math.max(1, tonumber(opts.limit) or 50)

	local query = vim.trim(tostring(search or ""))
	if query == "" then
		on_done({}, "Missing search query")
		return nil
	end
	query = issue_search_query(query)

	local cache_key = string.format("github_issues:search:%s:%d", query, limit)
	if not opts.force_load then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	logger.loginfo("GitHub GraphQL issues search", { query = query, limit = limit })
	return cli.gh({
		"api",
		"graphql",
		"-f",
		"query=" .. vim.trim(SEARCH_GQL),
		"-f",
		"search=" .. query,
		"-F",
		"limit=" .. tostring(limit),
	}, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local nodes = type(result) == "table"
				and type(result.data) == "table"
				and type(result.data.search) == "table"
				and result.data.search.nodes
			or nil
		local issues = normalizer.normalize_graphql_search_results(type(nodes) == "table" and nodes or {})
		cli.set_cache(cache_key, issues)
		on_done(issues, nil)
	end)
end

---@param key string
---@param on_done fun(issue: Issue|nil, err: string|nil)
---@param opts { force_load?: boolean }|nil
---@return { cancel: fun() }|nil
function M.get_issue(key, on_done, opts)
	opts = opts or {}
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		on_done(nil, "Invalid issue key: " .. tostring(key))
		return nil
	end

	local cache_key = string.format("github_issues:get:%s#%d", slug, number)
	if not opts.force_load then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	logger.loginfo("GitHub fetch issue", { slug = slug, number = number })
	return cli.gh({
		"issue",
		"view",
		tostring(number),
		"--repo",
		slug,
		"--json",
		DETAIL_JSON_FIELDS,
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		local issue = normalizer.normalize_issue(result, slug)
		if issue then
			cli.set_cache(cache_key, issue)
		end
		on_done(issue, nil)
	end)
end

---@param key string
---@param state "open"|"closed"
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_state(key, state, on_done)
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		on_done(false, "Invalid issue key")
		return nil
	end

	local sub = state == "closed" and "close" or "reopen"
	logger.loginfo("GitHub issue state change", { slug = slug, number = number, state = state })
	return cli.gh({ "issue", sub, tostring(number), "--repo", slug }, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		cli.delete_cache(string.format("github_issues:get:%s#%d", slug, number))
		on_done(true, nil)
	end)
end

---@param key string
---@param diff { add?: string[], remove?: string[] }
---@param add_flag string
---@param remove_flag string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function edit_issue_diff(key, diff, add_flag, remove_flag, on_done)
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		on_done(false, "Invalid issue key")
		return nil
	end

	local adds = type(diff) == "table" and diff.add or {}
	local removes = type(diff) == "table" and diff.remove or {}
	if #adds == 0 and #removes == 0 then
		on_done(true, nil)
		return nil
	end

	local args = { "issue", "edit", tostring(number), "--repo", slug }
	for _, v in ipairs(adds) do
		table.insert(args, add_flag)
		table.insert(args, tostring(v))
	end
	for _, v in ipairs(removes) do
		table.insert(args, remove_flag)
		table.insert(args, tostring(v))
	end

	return cli.gh(args, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		cli.delete_cache(string.format("github_issues:get:%s#%d", slug, number))
		on_done(true, nil)
	end)
end

---@param key string
---@param diff { add?: string[], remove?: string[] }
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_assignees(key, diff, on_done)
	return edit_issue_diff(key, diff, "--add-assignee", "--remove-assignee", on_done)
end

---@param key string
---@param diff { add?: string[], remove?: string[] }
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_labels(key, diff, on_done)
	return edit_issue_diff(key, diff, "--add-label", "--remove-label", on_done)
end

---@param slug string
---@param on_done fun(labels: { name: string, color: string|nil, description: string|nil }[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_labels(slug, on_done)
	-- Re-export from pulls/github to keep one source of truth.
	local pulls_issues = require("atlas.pulls.providers.github.api.issues")
	return pulls_issues.list_labels(slug, on_done)
end

---@param slug string
---@param on_done fun(assignees: { login: string, name: string|nil }[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_assignees(slug, on_done)
	local pulls_issues = require("atlas.pulls.providers.github.api.issues")
	return pulls_issues.list_assignees(slug, on_done)
end

return M
