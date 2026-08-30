local M = {}

local cli = require("atlas.providers.github.client")
local cache = require("atlas.issues.providers.github.api.cache")
local normalizer = require("atlas.issues.providers.github.api.mapper")
local json = require("atlas.core.json")

local ISSUE_FIELDS_GQL = [[
fragment IssueFields on Issue {
  id number title state isPinned viewerSubscription
  createdAt updatedAt closedAt url
  repository { nameWithOwner }
  author { login ... on User { name } }
  assignees(first: 1) { nodes { login name } }
  comments { totalCount }
}
]]

local ISSUE_REF_FIELDS_GQL = [[
fragment IssueRefFields on Issue {
  number title
  repository { nameWithOwner }
}
]]

local SEARCH_GQL = [[
query($search: String!, $limit: Int!, $after: String) {
  search(query: $search, type: ISSUE, first: $limit, after: $after) {
    issueCount
    nodes {
      ... on Issue {
        ...IssueFields
        parent { ...IssueRefFields }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
]] .. ISSUE_FIELDS_GQL .. ISSUE_REF_FIELDS_GQL

local DETAIL_GQL = [[
query($owner: String!, $repo: String!, $number: Int!, $withRelationships: Boolean!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      body
      assignees(first: 100) { nodes { login name } }
      labels(first: 100) { nodes { name color } }
      milestone {
        title progressPercentage
        openIssues: issues(states: OPEN) { totalCount }
        closedIssues: issues(states: CLOSED) { totalCount }
      }
      subIssues(first: 20) @include(if: $withRelationships) {
        nodes {
          ...IssueFields
          parent { ...IssueRefFields }
        }
      }
    }
  }
}
]] .. ISSUE_FIELDS_GQL .. ISSUE_REF_FIELDS_GQL

local ASSIGNEES_GQL = [[
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      assignees(first: 100) { nodes { login name } }
    }
    assignableUsers(first: 100) { nodes { login name } }
  }
}
]]

---@param search string
---@param on_done fun(page: IssuesPage, err: string|nil)
---@param opts IssuesFetchOpts
---@return { cancel: fun() }|nil
function M.search_issues(search, on_done, opts)
	local query = vim.trim(search)
	if query == "" then
		on_done({ items = {} }, "Missing search query")
		return nil
	end
	local cache_key = string.format("github_issues:search:v6:%s:%d:%s", query, opts.pagelen, opts.cursor or "first")
	if not opts.force_refresh then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local args = {
		"api",
		"graphql",
		"-f",
		"query=" .. vim.trim(SEARCH_GQL),
		"-f",
		"search=" .. query,
		"-F",
		"limit=" .. tostring(opts.pagelen),
	}
	if opts.cursor ~= nil then
		vim.list_extend(args, { "-f", "after=" .. opts.cursor })
	end

	return cli.gh(args, function(result, err)
		if err or type(result) ~= "table" then
			on_done({ items = {} }, err or "Failed to search issues")
			return
		end

		local search_result = result.data.search
		local page = {
			items = normalizer.to_search_results(search_result.nodes or {}),
			next_cursor = search_result.pageInfo.hasNextPage and search_result.pageInfo.endCursor or nil,
			total_pages = math.max(1, math.ceil(math.min(search_result.issueCount, 1000) / opts.pagelen)),
		}
		cli.set_cache(cache_key, page)
		on_done(page, nil)
	end, {
		action = "GraphQL issues search",
		query = query,
		limit = opts.pagelen,
	})
end

---@param key string
---@param on_done fun(details: IssueDetails|nil, err: string|nil)
---@param opts { force_refresh?: boolean }|nil
---@return { cancel: fun() }|nil
function M.get_issue(key, on_done, opts)
	opts = opts or {}
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		on_done(nil, "Invalid issue key: " .. tostring(key))
		return nil
	end

	local issues_cfg = require("atlas.config").options.issues or {}
	local with_relationships = issues_cfg.with_relationships ~= false
	local cache_key =
		string.format("github_issues:details:%s#%d:relationships:%s", slug, number, tostring(with_relationships))
	if not opts.force_refresh then
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
		local details = normalizer.to_issue_details(repository and repository.issue, slug)
		if details then
			cli.set_mem(cache_key, details)
		end
		on_done(details, nil)
	end, {
		action = "Fetch issue",
		slug = slug,
		number = number,
	})
end

---@param refs IssueRef[]
---@param _opts IssuesFetchOpts
---@param on_done fun(issues: Issue[], err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_by_refs(refs, _opts, on_done)
	local queries = {}

	for _, ref in ipairs(refs) do
		local slug, number = normalizer.parse_key(ref.key)
		local owner, repo = slug:match("^([^/]+)/(.+)$")
		if number == nil or owner == nil or repo == nil then
			on_done({}, "Invalid issue key: " .. tostring(ref.key))
			return nil
		end
		table.insert(queries, { slug = slug, owner = owner, repo = repo, number = number })
	end

	if #queries == 0 then
		on_done({}, nil)
		return nil
	end

	local variables = {}
	local selections = {}
	local args = { "api", "graphql" }
	for index, ref in ipairs(queries) do
		ref.alias = "item" .. index
		table.insert(variables, string.format("$owner%d: String!", index))
		table.insert(variables, string.format("$repo%d: String!", index))
		table.insert(variables, string.format("$number%d: Int!", index))
		table.insert(
			selections,
			string.format(
				"  %s: repository(owner: $owner%d, name: $repo%d) { issue(number: $number%d) { ...IssueFields parent { ...IssueRefFields } } }",
				ref.alias,
				index,
				index,
				index
			)
		)
		table.insert(args, "-f")
		table.insert(args, string.format("owner%d=%s", index, ref.owner))
		table.insert(args, "-f")
		table.insert(args, string.format("repo%d=%s", index, ref.repo))
		table.insert(args, "-F")
		table.insert(args, string.format("number%d=%d", index, ref.number))
	end

	local query = string.format(
		"query(%s) {\n%s\n}\n%s",
		table.concat(variables, ", "),
		table.concat(selections, "\n"),
		ISSUE_FIELDS_GQL .. ISSUE_REF_FIELDS_GQL
	)
	table.insert(args, "-f")
	table.insert(args, "query=" .. query)

	return cli.gh(args, function(result, err)
		if err or type(result) ~= "table" then
			on_done({}, err or "Failed to fetch issues")
			return
		end

		local data = json.nilify(result.data)
		if type(data) ~= "table" then
			on_done({}, "Empty response")
			return
		end

		local issues = {}
		for _, ref in ipairs(queries) do
			local repository = json.nilify(data[ref.alias])
			local raw = type(repository) == "table" and json.nilify(repository.issue) or nil
			local issue = normalizer.to_issue(raw, ref.slug)
			if issue then
				table.insert(issues, issue)
			end
		end
		on_done(issues, nil)
	end, {
		action = "Fetch issues by refs",
		count = #refs,
	})
end

---@param key string
---@param on_done fun(assignees: IssueUser[]|nil, assignable_users: IssueUser[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_assignee_options(key, on_done)
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		on_done(nil, nil, "Invalid issue key: " .. tostring(key))
		return nil
	end

	local owner, repo = slug:match("^([^/]+)/(.+)$")
	if owner == nil or repo == nil then
		on_done(nil, nil, "Invalid issue repository: " .. tostring(slug))
		return nil
	end

	return cli.gh({
		"api",
		"graphql",
		"-f",
		"query=" .. vim.trim(ASSIGNEES_GQL),
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. repo,
		"-F",
		"number=" .. tostring(number),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, nil, err or "Empty response")
			return
		end

		local data = json.nilify(result.data)
		local repository = type(data) == "table" and json.nilify(data.repository) or nil
		local issue = type(repository) == "table" and json.nilify(repository.issue) or nil
		if type(issue) ~= "table" then
			on_done(nil, nil, "Issue not found: " .. tostring(key))
			return
		end

		local function users(connection)
			local result_users = {}
			for _, raw in ipairs(json.safe_table(json.safe_table(connection).nodes)) do
				local user = normalizer.to_user(raw)
				if user then
					table.insert(result_users, user)
				end
			end
			return result_users
		end

		on_done(users(issue.assignees), users(repository.assignableUsers), nil)
	end, {
		action = "Fetch issue assignee options",
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

---@param endpoint string
---@param context table
---@param on_done fun(labels: { name: string, color: string|nil, description: string|nil }[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_labels(endpoint, context, on_done)
	return cli.gh({ "api", "--paginate", "--slurp", endpoint }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch labels")
			return
		end

		local labels = {}
		for _, page in ipairs(result) do
			for _, raw in ipairs(page) do
				local name = json.safe_str(raw.name)
				if name then
					table.insert(labels, {
						name = name,
						color = json.safe_str(raw.color),
						description = json.safe_str(raw.description),
					})
				end
			end
		end
		on_done(labels, nil)
	end, context)
end

---@param key string
---@param on_done fun(labels: IssueLabel[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue_labels(key, on_done)
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		on_done(nil, "Invalid issue key: " .. tostring(key))
		return nil
	end

	return fetch_labels(string.format("repos/%s/issues/%d/labels?per_page=100", slug, number), {
		action = "Fetch issue labels",
		slug = slug,
		number = number,
	}, on_done)
end

---@param slug string
---@param on_done fun(labels: { name: string, color: string|nil, description: string|nil }[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_labels(slug, on_done)
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	return fetch_labels(string.format("repos/%s/labels?per_page=100", slug), {
		action = "Fetch repo labels",
		slug = slug,
	}, on_done)
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
	if slug == "" then
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
