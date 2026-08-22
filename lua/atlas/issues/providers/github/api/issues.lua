local M = {}

local cli = require("atlas.providers.github.client").issues
local cache = require("atlas.issues.providers.github.api.cache")
local normalizer = require("atlas.issues.providers.github.api.mapper")
local json = require("atlas.core.json")

local SEARCH_GQL = [[
query($search: String!, $limit: Int!, $withRelationships: Boolean!) {
  search(query: $search, type: ISSUE, first: $limit) {
    nodes {
      ... on Issue {
        ...IssueFields
        parent @include(if: $withRelationships) { ...IssueFields }
        subIssues(first: 20) @include(if: $withRelationships) {
          nodes {
            ...IssueFields
            parent { ...IssueFields }
          }
        }
      }
    }
  }
}

fragment IssueFields on Issue {
  number title state isPinned
  createdAt updatedAt url
  repository { nameWithOwner }
  author { login ... on User { name } }
  assignees(first: 1) { nodes { login name } }
  comments { totalCount }
}
]]

local DETAIL_GQL = [[
query($owner: String!, $repo: String!, $number: Int!, $withRelationships: Boolean!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      ...IssueFields
      body
      reactionGroups { content reactors { totalCount } }
      parent @include(if: $withRelationships) {
        ...IssueFields
        reactionGroups { content reactors { totalCount } }
      }
      subIssues(first: 20) @include(if: $withRelationships) {
        nodes {
          ...IssueFields
          reactionGroups { content reactors { totalCount } }
          parent {
            ...IssueFields
            reactionGroups { content reactors { totalCount } }
          }
        }
      }
    }
  }
}

fragment IssueFields on Issue {
  id number title state isPinned viewerSubscription
  createdAt updatedAt closedAt url
  repository { nameWithOwner }
  author { login ... on User { name } }
  assignees(first: 10) { nodes { login name } }
  labels(first: 20) { nodes { name color } }
  milestone {
    number title state description progressPercentage
    openIssues: issues(states: OPEN) { totalCount }
    closedIssues: issues(states: CLOSED) { totalCount }
  }
  comments { totalCount }
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

---@param opts { with_relationships?: boolean, layout?: "plain"|"compact" }|nil
---@return boolean
local function relationships_enabled(opts)
	opts = opts or {}
	if opts.with_relationships == false or opts.layout == "compact" then
		return false
	end

	local issues_cfg = require("atlas.config").options.issues or {}
	return issues_cfg.with_relationships ~= false
end

---@param search string
---@param on_done fun(issues: Issue[]|nil, err: string|nil)
---@param opts { force_load?: boolean, limit?: number, with_relationships?: boolean, layout?: "plain"|"compact" }|nil
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

	local with_relationships = relationships_enabled(opts)
	local cache_key =
		string.format("github_issues:search:%s:%d:relationships:%s", query, limit, tostring(with_relationships))
	if not opts.force_load then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"api",
		"graphql",
		"-f",
		"query=" .. vim.trim(SEARCH_GQL),
		"-f",
		"search=" .. query,
		"-F",
		"limit=" .. tostring(limit),
		"-F",
		"withRelationships=" .. tostring(with_relationships),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to search issues")
			return
		end

		local issues = normalizer.to_search_results(result.data.search.nodes or {})
		cli.set_cache(cache_key, issues)
		on_done(issues, nil)
	end, {
		action = "GraphQL issues search",
		query = query,
		limit = limit,
	})
end

---@param key string
---@param on_done fun(issue: IssueDetails|nil, err: string|nil)
---@param opts { force_load?: boolean, with_relationships?: boolean, layout?: "plain"|"compact" }|nil
---@return { cancel: fun() }|nil
function M.get_issue(key, on_done, opts)
	opts = opts or {}
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		on_done(nil, "Invalid issue key: " .. tostring(key))
		return nil
	end

	local with_relationships = relationships_enabled(opts)
	local cache_key =
		string.format("github_issues:get:%s#%d:relationships:%s", slug, number, tostring(with_relationships))
	if not opts.force_load then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local owner, repo = slug:match("^([^/]+)/(.+)$")
	if owner == nil or repo == nil then
		on_done(nil, "Invalid issue repository: " .. tostring(slug))
		return nil
	end

	return cli.gh({
		"api",
		"graphql",
		"-f",
		"query=" .. vim.trim(DETAIL_GQL),
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. repo,
		"-F",
		"number=" .. tostring(number),
		"-F",
		"withRelationships=" .. tostring(with_relationships),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end

		local repository = json.nilify(result.data.repository)
		local issue = normalizer.to_issue_details(repository and repository.issue, slug)
		if issue then
			cli.set_mem(cache_key, issue)
		end
		on_done(issue, nil)
	end, {
		action = "Fetch issue",
		slug = slug,
		number = number,
	})
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
	return cli.gh({ "issue", sub, tostring(number), "--repo", slug }, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		cache.invalidate(key)
		on_done(true, nil)
	end, {
		action = "Issue state change",
		slug = slug,
		number = number,
		state = state,
	})
end

---@param key string
---@param diff { add?: string[], remove?: string[] }
---@param add_flag string
---@param remove_flag string
---@param on_done fun(ok: boolean, err: string|nil)
---@param ctx table|nil
---@return { cancel: fun() }|nil
local function edit_issue_diff(key, diff, add_flag, remove_flag, on_done, ctx)
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		on_done(false, "Invalid issue key")
		return nil
	end

	local adds = diff.add or {}
	local removes = diff.remove or {}
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
		cache.invalidate(key)
		on_done(true, nil)
	end, ctx)
end

---@param key string
---@param diff { add?: string[], remove?: string[] }
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_assignees(key, diff, on_done)
	return edit_issue_diff(key, diff, "--add-assignee", "--remove-assignee", on_done, {
		action = "Update issue assignees",
		key = key,
		add = diff and diff.add,
		remove = diff and diff.remove,
	})
end

---@param key string
---@param diff { add?: string[], remove?: string[] }
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_labels(key, diff, on_done)
	return edit_issue_diff(key, diff, "--add-label", "--remove-label", on_done, {
		action = "Update issue labels",
		key = key,
		add = diff and diff.add,
		remove = diff and diff.remove,
	})
end

---@param slug string
---@param on_done fun(labels: { name: string, color: string|nil, description: string|nil }[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_labels(slug, on_done)
	if type(slug) ~= "string" or slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	return cli.gh({
		"api",
		"--paginate",
		"--slurp",
		string.format("repos/%s/labels?per_page=100", slug),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch labels")
			return
		end

		local list = {}
		for _, page in ipairs(result) do
			for _, raw in ipairs(page) do
				local name = json.safe_str(raw.name)
				if name then
					table.insert(list, {
						name = name,
						color = json.safe_str(raw.color),
						description = json.safe_str(raw.description),
					})
				end
			end
		end
		on_done(list, nil)
	end, {
		action = "Fetch repo labels",
		slug = slug,
	})
end

---@class GitHubMilestone
---@field number integer
---@field title string
---@field state string|nil
---@field description string|nil
---@field progressPercentage number|nil
---@field openIssues { totalCount: integer }|nil
---@field closedIssues { totalCount: integer }|nil

---@param slug string
---@param on_done fun(milestones: GitHubMilestone[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_milestones(slug, on_done)
	if type(slug) ~= "string" or slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	return cli.gh({
		"api",
		"--paginate",
		"--slurp",
		string.format("repos/%s/milestones?state=open&per_page=100", slug),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch milestones")
			return
		end

		local list = {}
		for _, page in ipairs(result) do
			for _, raw in ipairs(page) do
				local number = tonumber(raw.number)
				local title = json.safe_str(raw.title)
				if number and title then
					table.insert(list, {
						number = number,
						title = title,
						state = json.safe_str(raw.state),
						description = json.safe_str(raw.description),
					})
				end
			end
		end
		on_done(list, nil)
	end, {
		action = "Fetch repo milestones",
		slug = slug,
	})
end

---@class GitHubCreateIssueOpts
---@field repo_slug string
---@field title string
---@field body string|nil
---@field labels string[]|nil
---@field assignees string[]|nil
---@field milestone string|nil

---@param opts GitHubCreateIssueOpts
---@param on_done fun(result: { number: integer|nil, url: string|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_issue(opts, on_done)
	local slug = tostring(opts.repo_slug or "")
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	local title = tostring(opts.title or "")
	if vim.trim(title) == "" then
		vim.schedule(function()
			on_done(nil, "Title is required")
		end)
		return nil
	end

	local args = {
		"issue",
		"create",
		"--repo",
		slug,
		"--title",
		title,
		"--body",
		tostring(opts.body or ""),
	}

	for _, label in ipairs(opts.labels or {}) do
		if label ~= "" then
			table.insert(args, "--label")
			table.insert(args, label)
		end
	end

	for _, login in ipairs(opts.assignees or {}) do
		if login ~= "" then
			table.insert(args, "--assignee")
			table.insert(args, login)
		end
	end

	if opts.milestone then
		table.insert(args, "--milestone")
		table.insert(args, opts.milestone)
	end

	return cli.gh(args, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local url = nil
		local number = nil
		if type(result) == "string" then
			url = vim.trim(result)
			local match = url:match("/issues/(%d+)")
			if match then
				number = tonumber(match) or match
			end
		end

		on_done({ number = number, url = url }, nil)
	end, {
		action = "Create issue",
		slug = slug,
		labels = opts.labels,
		assignees = opts.assignees,
		milestone = opts.milestone,
	})
end

return M
