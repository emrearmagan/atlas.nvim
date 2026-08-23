local M = {}

local request_scope = require("atlas.core.requests")
local cli = require("atlas.providers.github.client")
local json = require("atlas.core.json")

local ISSUE_TYPE_COLORS = {
	RED = "d73a49",
	ORANGE = "e36209",
	YELLOW = "dbab09",
	GREEN = "28a745",
	TEAL = "0e8a16",
	BLUE = "0366d6",
	PURPLE = "6f42c1",
	PINK = "d876e3",
	GRAY = "6a737d",
}

local ISSUES_QUERY = [[
query($owner: String!, $repo: String!, $states: [IssueState!]!) {
  repository(owner: $owner, name: $repo) {
    open: issues(states: OPEN) { totalCount }
    closed: issues(states: CLOSED) { totalCount }
    issues(first: 50, states: $states, orderBy: {field: CREATED_AT, direction: DESC}) {
      nodes {
        number title state url createdAt
        author { login }
        issueType { name color }
        comments { totalCount }
      }
    }
  }
}
]]

---@param repo PullsRepo
---@param opts PullsFetchOpts
---@param on_done fun(details: PullsRepoDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_detail(repo, opts, on_done)
	local owner = tostring(repo.owner or "")
	local repo_name = tostring(repo.repo_name or repo.name or "")

	if owner == "" or repo_name == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local slug = owner .. "/" .. repo_name
	local cache_key = string.format("github:repo_details:%s", slug)

	if not opts.force_load then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local requests = request_scope.new()
	requests.run(function(done)
		return cli.gh({
			"repo",
			"view",
			slug,
			"--json",
			"name,nameWithOwner,owner,description,defaultBranchRef,isPrivate,createdAt,diskUsage,url,stargazerCount,forkCount,watchers",
		}, done)
	end, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch repo details")
			return
		end

		local result_owner = json.safe_table(result.owner)
		local default_branch = json.nilify(result.defaultBranchRef)
		local watchers = json.safe_table(result.watchers)

		---@type PullsRepoDetails
		local details = {
			id = tostring(result.nameWithOwner or slug),
			name = tostring(result.name or repo_name),
			full_name = tostring(result.nameWithOwner or slug),
			owner = tostring(result_owner.login or owner),
			repo_name = tostring(result.name or repo_name),
			html_url = tostring(result.url or ""),
			description = tostring(result.description or ""),
			size = tonumber(result.diskUsage) or nil,
			default_branch = default_branch and tostring(default_branch.name or "") or nil,
			is_private = result.isPrivate == true,
			created_on = tostring(result.createdAt or ""),
			readme = nil,
			stars = tonumber(result.stargazerCount) or nil,
			forks = tonumber(result.forkCount) or nil,
			watchers = tonumber(watchers.totalCount),
		}

		requests.run(function(done)
			return cli.gh({
				"api",
				string.format("repos/%s/readme", slug),
				"--header",
				"Accept: application/vnd.github.raw+json",
			}, done)
		end, function(readme_result, readme_err)
			if not readme_err and readme_result then
				details.readme = tostring(readme_result)
			end
			cli.set_mem(cache_key, details)
			on_done(details, nil)
		end)
	end)
	return requests
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(branches: PullsRepoBranches|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_branches(repo, opts, on_done)
	local slug = tostring(repo.full_name or "")
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local cache_key = string.format("github:branches:%s", slug)
	if not opts.force_load then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"api",
		string.format("repos/%s/branches?per_page=100", slug),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch branches")
			return
		end

		local entries = {}
		for _, branch in ipairs(result) do
			local commit = branch.commit
			table.insert(entries, {
				name = tostring(branch.name or ""),
				hash = tostring(commit.sha or ""):sub(1, 8),
				date = nil,
				message = nil,
				author = nil,
			})
		end

		local branches = { entries = entries }
		cli.set_mem(cache_key, branches)
		on_done(branches, nil)
	end)
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(tags: PullsRepoTags|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_tags(repo, opts, on_done)
	local slug = tostring(repo.full_name or "")
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local cache_key = string.format("github:tags:%s", slug)
	if not opts.force_load then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"api",
		string.format("repos/%s/tags?per_page=100", slug),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch tags")
			return
		end

		local entries = {}
		for _, tag in ipairs(result) do
			local commit = tag.commit
			table.insert(entries, {
				name = tostring(tag.name or ""),
				hash = tostring(commit.sha or ""):sub(1, 8),
				date = nil,
				message = nil,
				author = nil,
			})
		end

		local tags = { entries = entries }
		cli.set_mem(cache_key, tags)
		on_done(tags, nil)
	end)
end

---@param repo PullsRepoDetails
---@param state "open"|"closed"
---@param _opts PullsFetchOpts
---@param on_done fun(result: { entries: PullsRepoIssue[], counts: { open: integer, closed: integer }|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issues(repo, state, _opts, on_done)
	local slug = tostring(repo.full_name or "")
	local parts = vim.split(slug, "/", { plain = true })
	local owner = parts[1] or ""
	local repo_name = parts[2] or ""
	if owner == "" or repo_name == "" then
		on_done(nil, "Missing repository info")
		return nil
	end

	return cli.gh({
		"api",
		"graphql",
		"-f",
		"query=" .. vim.trim(ISSUES_QUERY),
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. repo_name,
		"-f",
		"states=" .. (state == "open" and "OPEN" or "CLOSED"),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch repository issues")
			return
		end

		local data = json.nilify(result.data.repository)
		if data == nil then
			on_done({ entries = {}, counts = nil }, nil)
			return
		end

		local entries = {}
		for _, raw in ipairs(data.issues.nodes or {}) do
			local raw_issue_type = json.nilify(raw.issueType)
			local issue_type = nil
			if raw_issue_type then
				issue_type = {
					name = json.safe_str(raw_issue_type.name) or "",
					color = ISSUE_TYPE_COLORS[(json.safe_str(raw_issue_type.color) or ""):upper()]
						or ISSUE_TYPE_COLORS.GRAY,
				}
			end
			local author = json.nilify(raw.author)
			table.insert(entries, {
				number = raw.number,
				title = json.safe_str(raw.title) or "",
				state = (json.safe_str(raw.state) or ""):lower(),
				author = author and (json.safe_str(author.login) or "") or "",
				created_at = json.safe_str(raw.createdAt) or "",
				comments = tonumber(raw.comments.totalCount) or 0,
				url = json.safe_str(raw.url) or "",
				issue_type = issue_type,
			})
		end

		on_done({
			entries = entries,
			counts = {
				open = tonumber(data.open.totalCount) or 0,
				closed = tonumber(data.closed.totalCount) or 0,
			},
		}, nil)
	end)
end

return M
