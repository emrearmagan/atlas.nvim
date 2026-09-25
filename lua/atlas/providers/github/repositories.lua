local M = {}

local request_scope = require("atlas.core.requests")
local cli = require("atlas.providers.github.client")
local json = require("atlas.core.json")
local utils = require("atlas.core.utils")

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

local ISSUE_SUMMARY_QUERY = [[
query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    open: issues(states: OPEN) { totalCount }
    closed: issues(states: CLOSED) { totalCount }
    unassigned: issues(states: OPEN, filterBy: {assignee: null}) { totalCount }
    labels { totalCount }
    milestones(states: OPEN) { totalCount }
  }
}
]]

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

local BRANCHES_QUERY = [[
query($owner: String!, $repo: String!, $endCursor: String, $search: String) {
  repository(owner: $owner, name: $repo) {
    refs(refPrefix: "refs/heads/", first: 100, after: $endCursor, query: $search, orderBy: {field: ALPHABETICAL, direction: ASC}) {
      nodes {
        name
        target {
          ... on Commit {
            oid committedDate message
            author { name }
          }
        }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
]]

local TAGS_QUERY = [[
query($owner: String!, $repo: String!, $endCursor: String, $search: String) {
  repository(owner: $owner, name: $repo) {
    url
    refs(refPrefix: "refs/tags/", first: 100, after: $endCursor, query: $search, orderBy: {field: TAG_COMMIT_DATE, direction: DESC}) {
      nodes {
        name
        target {
          oid
          ... on Commit {
            message
            author { name }
          }
          ... on Tag {
            annotation: message
            tagger { name date }
            target {
              oid
              ... on Commit {
                message
                author { name }
              }
            }
          }
        }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
]]

local RELEASES_QUERY = [[
query($owner: String!, $repo: String!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    releases(first: 100, after: $endCursor, orderBy: {field: CREATED_AT, direction: DESC}) {
      nodes {
        databaseId name tagName url publishedAt isDraft isPrerelease
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
]]

---@param repo AtlasRepository
---@param on_done fun(details: AtlasRepositoryDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_details(repo, on_done)
	local owner = tostring(repo.owner or "")
	local repo_name = tostring(repo.repo_name or repo.name or "")

	if owner == "" or repo_name == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local slug = owner .. "/" .. repo_name

	local requests = request_scope.new()
	requests.all({
		details = function(done)
			return cli.gh(
				{
					"repo",
					"view",
					slug,
					"--json",
					"name,nameWithOwner,owner,description,defaultBranchRef,isPrivate,createdAt,diskUsage,url,stargazerCount,forkCount,watchers,repositoryTopics",
				},
				done,
				{
					action = "Fetch repository",
					repo = slug,
				}
			)
		end,
		readme = function(done)
			return cli.gh(
				{
					"api",
					string.format("repos/%s/readme", slug),
					"--header",
					"Accept: application/vnd.github.raw+json",
				},
				done,
				{
					action = "Fetch repository README",
					repo = slug,
				}
			)
		end,
	}, function(results, errors)
		local result = results.details
		if errors.details or type(result) ~= "table" then
			on_done(nil, errors.details or "Failed to fetch repo details")
			return
		end

		local result_owner = json.safe_table(result.owner)
		local default_branch = json.nilify(result.defaultBranchRef)
		local watchers = json.safe_table(result.watchers)

		---@type AtlasRepositoryDetails
		local details = {
			id = tostring(result.nameWithOwner or slug),
			name = tostring(result.name or repo_name),
			full_name = tostring(result.nameWithOwner or slug),
			owner = tostring(result_owner.login or owner),
			repo_name = tostring(result.name or repo_name),
			html_url = tostring(result.url or ""),
			description = tostring(result.description or ""),
			topics = vim.tbl_map(function(topic)
				return topic.name
			end, json.safe_table(result.repositoryTopics)),
			size = tonumber(result.diskUsage) or nil,
			default_branch = default_branch and tostring(default_branch.name or "") or nil,
			is_private = result.isPrivate == true,
			created_on = tostring(result.createdAt or ""),
			readme = nil,
			stars = tonumber(result.stargazerCount) or nil,
			forks = tonumber(result.forkCount) or nil,
			watchers = tonumber(watchers.totalCount),
		}

		if not errors.readme and results.readme then
			details.readme = tostring(results.readme)
		end
		on_done(details, nil)
	end)
	return requests
end

---@param slug string
---@param query string
---@param opts { cursor?: string, search?: string }
---@param on_done fun(repository: table|nil, err: string|nil, next_cursor: string|nil)
---@return { cancel: fun() }|nil
local function fetch_refs(slug, query, opts, on_done)
	local owner, name = slug:match("^([^/]+)/([^/]+)$")
	if not owner then
		on_done(nil, "Missing repository info", nil)
		return nil
	end
	local args = { "api", "graphql", "-f", "query=" .. query, "-f", "owner=" .. owner, "-f", "repo=" .. name }
	if opts.cursor then
		vim.list_extend(args, { "-f", "endCursor=" .. opts.cursor })
	end
	if opts.search and opts.search ~= "" then
		vim.list_extend(args, { "-f", "search=" .. opts.search })
	end
	return cli.gh(args, function(result, err)
		if err then
			on_done(nil, err, nil)
			return
		end
		local data = json.safe_table(result and result.data)
		local repository = json.nilify(data.repository)
		if not repository then
			on_done(nil, "Repository not found", nil)
			return
		end
		local page = repository.refs.pageInfo
		on_done(repository, nil, page.hasNextPage and page.endCursor or nil)
	end, { action = "Fetch repository refs", repo = slug })
end

---@param repo AtlasRepository
---@param opts { cursor?: string, search?: string }
---@param on_done fun(branches: AtlasRepositoryBranches|nil, err: string|nil, next_cursor: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_branches(repo, opts, on_done)
	local slug = repo.full_name

	return fetch_refs(slug, BRANCHES_QUERY, opts, function(repository, err, next_cursor)
		if not repository then
			on_done(nil, err, nil)
			return
		end
		---@type AtlasRepositoryBranches
		local branches = { entries = {} }
		for _, branch in ipairs(repository.refs.nodes) do
			local commit = json.safe_table(branch.target)
			local author = json.safe_table(commit.author)
			table.insert(branches.entries, {
				name = json.safe_str(branch.name) or "",
				hash = json.safe_str(commit.oid) or "",
				date = json.safe_str(commit.committedDate),
				message = json.safe_str(commit.message),
				author = json.safe_str(author.name),
			})
		end
		on_done(branches, nil, next_cursor)
	end)
end

---@param repo AtlasRepository
---@param opts { cursor?: string, search?: string }
---@param on_done fun(tags: AtlasRepositoryTag[]|nil, err: string|nil, next_cursor: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_tags(repo, opts, on_done)
	local slug = repo.full_name

	return fetch_refs(slug, TAGS_QUERY, opts, function(repository, err, next_cursor)
		if not repository then
			on_done(nil, err, nil)
			return
		end
		---@type AtlasRepositoryTag[]
		local tags = {}
		for _, tag in ipairs(repository.refs.nodes) do
			local target = json.safe_table(tag.target)
			local commit = json.safe_table(json.nilify(target.target) or target)
			local tagger = json.safe_table(target.tagger)
			local author = json.safe_table(commit.author)
			local tag_name = json.safe_str(tag.name) or ""
			local annotation = json.safe_str(target.annotation)
			if annotation == "" then
				annotation = nil
			end
			table.insert(tags, {
				name = tag_name,
				hash = json.safe_str(commit.oid) or "",
				tag_date = json.safe_str(tagger.date),
				description = annotation,
				message = annotation or json.safe_str(commit.message),
				author = json.safe_str(tagger.name) or json.safe_str(author.name),
				url = repository.url .. "/releases/tag/" .. utils.url_encode(tag_name),
			})
		end
		on_done(tags, nil, next_cursor)
	end)
end

---@param repo AtlasRepository
---@param on_done fun(releases: AtlasRepositoryRelease[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_releases(repo, on_done)
	local slug = tostring(repo.full_name or "")
	local owner, name = slug:match("^([^/]+)/([^/]+)$")
	if not owner then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	return cli.gh({
		"api",
		"graphql",
		"--paginate",
		"--slurp",
		"-f",
		"query=" .. RELEASES_QUERY,
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. name,
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch releases")
			return
		end

		---@type AtlasRepositoryRelease[]
		local entries = {}
		for _, page in ipairs(result) do
			local data = json.safe_table(page.data)
			local repository = json.nilify(data.repository)
			if not repository then
				on_done(nil, "Repository not found")
				return
			end

			local releases = json.safe_table(repository.releases)
			for _, release in ipairs(json.safe_table(releases.nodes)) do
				local tag = json.safe_str(release.tagName) or ""
				local release_name = json.safe_str(release.name)
				table.insert(entries, {
					id = tostring(release.databaseId),
					name = release_name and release_name ~= "" and release_name or tag,
					tag = tag,
					url = json.safe_str(release.url) or "",
					published_at = json.safe_str(release.publishedAt),
					draft = release.isDraft == true,
					prerelease = release.isPrerelease == true,
				})
			end
		end

		on_done(entries, nil)
	end, {
		action = "Fetch repository releases",
		repo = slug,
	})
end

---@param repo AtlasRepository
---@param opts { id?: string }
---@param on_done fun(release: AtlasRepositoryReleaseDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_release(repo, opts, on_done)
	local slug = tostring(repo.full_name or "")
	if not slug:match("^[^/]+/[^/]+$") then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local endpoint = string.format("repos/%s/releases/%s", slug, opts.id or "latest")
	return cli.gh({ "api", endpoint }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch release")
			return
		end

		local author = json.safe_table(result.author)
		local tag = json.safe_str(result.tag_name) or ""
		local name = json.safe_str(result.name)
		---@type AtlasRepositoryReleaseAsset[]
		local assets = {}
		for _, asset in ipairs(json.safe_table(result.assets)) do
			table.insert(assets, {
				name = json.safe_str(asset.name) or "",
				url = json.safe_str(asset.browser_download_url) or "",
				size = tonumber(asset.size),
				downloads = tonumber(asset.download_count),
			})
		end
		for _, source in ipairs({
			{ name = "Source code (zip)", url = json.safe_str(result.zipball_url) },
			{ name = "Source code (tar.gz)", url = json.safe_str(result.tarball_url) },
		}) do
			if source.url and source.url ~= "" then
				table.insert(assets, source)
			end
		end

		on_done({
			id = tostring(result.id),
			name = name and name ~= "" and name or tag,
			tag = tag,
			description = json.safe_str(result.body) or "",
			url = json.safe_str(result.html_url) or "",
			author = json.safe_str(author.login),
			published_at = json.safe_str(result.published_at),
			draft = result.draft == true,
			prerelease = result.prerelease == true,
			assets = assets,
		}, nil)
	end, {
		action = "Fetch repository release",
		repo = slug,
		id = opts.id,
	})
end

---@param repo AtlasRepository
---@param on_done fun(summary: AtlasRepositoryIssueSummary|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue_summary(repo, on_done)
	local slug = tostring(repo.full_name or "")
	local owner, repo_name = slug:match("^([^/]+)/([^/]+)$")
	if owner == nil then
		on_done(nil, "Missing repository info")
		return nil
	end

	return cli.gh({
		"api",
		"graphql",
		"-f",
		"query=" .. vim.trim(ISSUE_SUMMARY_QUERY),
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. repo_name,
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch repository issue summary")
			return
		end

		local repository = json.safe_table(json.safe_table(result.data).repository)
		local open_count = tonumber(json.safe_table(repository.open).totalCount)
		local closed_count = tonumber(json.safe_table(repository.closed).totalCount)
		if open_count == nil or closed_count == nil then
			on_done(nil, "Invalid repository issue summary")
			return
		end

		local items = {}
		for _, item in ipairs({
			{ field = "unassigned", label = "Open unassigned" },
			{ field = "labels", label = "Labels" },
			{ field = "milestones", label = "Open milestones" },
		}) do
			local count = tonumber(json.safe_table(repository[item.field]).totalCount)
			if count ~= nil then
				table.insert(items, { label = item.label, value = count })
			end
		end

		on_done({ open = open_count, closed = closed_count, items = items }, nil)
	end, {
		action = "Fetch repository issue summary",
		repo = slug,
	})
end

---@param repo AtlasRepository
---@param state "open"|"closed"
---@param on_done fun(result: { entries: PullsRepoIssue[], counts: { open: integer, closed: integer }|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issues(repo, state, on_done)
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
	end, {
		action = "Fetch repository issues",
		repo = slug,
		state = state,
	})
end

---@param repo AtlasRepository
---@param branch AtlasRepositoryBranch
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_branch(repo, branch, on_done)
	local slug = tostring(repo.full_name or "")
	local name = tostring(branch.name or "")
	if not slug:match("^[^/]+/[^/]+$") or name == "" then
		vim.schedule(function()
			on_done(false, "Missing branch info")
		end)
		return nil
	end

	local endpoint = string.format("repos/%s/git/refs/heads/%s", slug, utils.url_encode(name))
	return cli.api("DELETE", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end, {
		action = "Delete repository branch",
		repo = slug,
		branch = name,
	})
end

return M
