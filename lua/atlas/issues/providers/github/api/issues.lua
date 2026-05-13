local M = {}

local cli = require("atlas.issues.providers.github.api.cli")
local normalizer = require("atlas.issues.providers.github.api.normalizer")
local logger = require("atlas.core.logger")

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
  createdAt updatedAt closedAt url body
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

---@class GitHubLabel
---@field name string
---@field color string|nil
---@field description string|nil

---@class GitHubAssignee
---@field login string
---@field name string|nil

---@class GitHubMilestone
---@field number integer
---@field title string
---@field state string|nil
---@field description string|nil
---@field progressPercentage number|nil
---@field openIssues { totalCount: integer }|nil
---@field closedIssues { totalCount: integer }|nil

---@class GitHubCreateIssueOpts
---@field repo_slug string
---@field title string
---@field body string|nil
---@field labels string[]|nil
---@field assignees string[]|nil
---@field milestone integer|nil

---@class GitHubCreateIssueResult
---@field number integer|nil
---@field url string|nil

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
	local cache_key = string.format("github_issues:search:v3:%s:%d:relationships:%s", query, limit, tostring(with_relationships))
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
		"-F",
		"withRelationships=" .. tostring(with_relationships),
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
	local cache_key = string.format("github_issues:get:v2:%s#%d:relationships:%s", slug, number, tostring(with_relationships))
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

	logger.loginfo("GitHub fetch issue", { slug = slug, number = number })
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

		local raw = type(result.data) == "table"
			and type(result.data.repository) == "table"
			and result.data.repository.issue
			or nil
		local issue = normalizer.normalize_issue(type(raw) == "table" and raw or {}, slug)
		if issue then
			cli.set_mem(cache_key, issue)
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
---@param on_done fun(labels: GitHubLabel[]|nil, err: string|nil)
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
		string.format("repos/%s/labels?per_page=100", slug),
	}, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local list = {}
		if type(result) == "table" then
			for _, raw in ipairs(result) do
				if type(raw) == "table" and type(raw.name) == "string" then
					table.insert(list, {
						name = raw.name,
						color = type(raw.color) == "string" and raw.color or nil,
						description = type(raw.description) == "string" and raw.description or nil,
					})
				end
			end
		end
		on_done(list, nil)
	end)
end

---@param slug string
---@param on_done fun(assignees: GitHubAssignee[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_assignees(slug, on_done)
	if type(slug) ~= "string" or slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	return cli.gh({
		"api",
		"--paginate",
		string.format("repos/%s/assignees?per_page=100", slug),
	}, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local list = {}
		if type(result) == "table" then
			for _, raw in ipairs(result) do
				if type(raw) == "table" and type(raw.login) == "string" then
					table.insert(list, {
						login = raw.login,
						name = type(raw.name) == "string" and raw.name or nil,
					})
				end
			end
		end
		on_done(list, nil)
	end)
end

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
		string.format("repos/%s/milestones?state=open&per_page=100", slug),
	}, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local list = {}
		if type(result) == "table" then
			for _, raw in ipairs(result) do
				if type(raw) == "table" and type(raw.number) == "number" and type(raw.title) == "string" then
					table.insert(list, {
						number = raw.number,
						title = raw.title,
						state = type(raw.state) == "string" and raw.state or nil,
						description = type(raw.description) == "string" and raw.description or nil,
					})
				end
			end
		end
		on_done(list, nil)
	end)
end

---@param opts GitHubCreateIssueOpts
---@param on_done fun(result: GitHubCreateIssueResult|nil, err: string|nil)
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

	if type(opts.labels) == "table" then
		for _, label in ipairs(opts.labels) do
			if type(label) == "string" and label ~= "" then
				table.insert(args, "--label")
				table.insert(args, label)
			end
		end
	end

	if type(opts.assignees) == "table" then
		for _, login in ipairs(opts.assignees) do
			if type(login) == "string" and login ~= "" then
				table.insert(args, "--assignee")
				table.insert(args, login)
			end
		end
	end

	if type(opts.milestone) == "number" then
		table.insert(args, "--milestone")
		table.insert(args, tostring(opts.milestone))
	end

	logger.loginfo("github.create_issue", {
		slug = slug,
		labels = opts.labels,
		assignees = opts.assignees,
		milestone = opts.milestone,
	})

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
	end)
end

return M
