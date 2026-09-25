local M = {}

local request_scope = require("atlas.core.requests")
local service = require("atlas.providers.gitlab.client")
local config = require("atlas.config")
local json = require("atlas.core.json")

local RELEASES_QUERY = [[
query($path: ID!, $cursor: String) {
  project(fullPath: $path) {
    releases(first: 100, after: $cursor) {
      nodes {
        name
        tagName
        releasedAt
        links { selfUrl }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
]]

local ISSUE_SUMMARY_QUERY = [[
query($path: ID!, $overdueBefore: Time!) {
  project(fullPath: $path) {
    issueStatusCounts { opened closed }
    unassigned: issueStatusCounts(assigneeId: "NONE") { opened }
    overdue: issueStatusCounts(dueBefore: $overdueBefore) { opened }
    labels { count }
  }
}
]]

---@param repo AtlasRepository
---@return string
local function configured_readme_path(repo)
	local repo_cfg = (((config.options or {}).pulls or {}).repo_config or {})
	local settings = repo_cfg.settings or {}
	local keys = { tostring(repo.id or ""), tostring(repo.name or "") }
	for _, key in ipairs(keys) do
		if key ~= "" then
			local entry = settings[key]
			if type(entry) == "table" and tostring(entry.readme or "") ~= "" then
				return tostring(entry.readme)
			end
		end
	end
	return "README.md"
end

---@param repo AtlasRepository
---@return string
local function repo_path(repo)
	local id = tostring(repo.id or "")
	if id ~= "" then
		return id
	end
	local owner = tostring(repo.owner or "")
	local name = tostring(repo.repo_name or repo.name or "")
	if owner == "" or name == "" then
		return ""
	end
	return owner .. "/" .. name
end

---@param repo AtlasRepository
---@param on_done fun(details: AtlasRepositoryDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_details(repo, on_done)
	local path = repo_path(repo)
	if path == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local endpoint = string.format("/projects/%s?statistics=true", service.url_encode(path))
	local requests = request_scope.new()
	requests.run(function(done)
		return service.request("GET", endpoint, nil, done, {
			action = "Fetch repository",
			repo = path,
		})
	end, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		result = json.safe_table(result)

		local name = json.safe_str(result.path) or tostring(repo.repo_name or repo.name or "")
		local full_path = json.safe_str(result.path_with_namespace) or path
		local owner = full_path:match("^(.-)/[^/]+$") or ""

		local statistics = json.safe_table(result.statistics)

		---@type AtlasRepositoryDetails
		local details = {
			id = full_path,
			name = name,
			full_name = full_path,
			owner = owner,
			repo_name = name,
			html_url = json.safe_str(result.web_url) or "",
			description = json.safe_str(result.description) or "",
			topics = json.safe_table(result.topics),
			size = tonumber(statistics.repository_size),
			default_branch = json.safe_str(result.default_branch) or "",
			is_private = json.safe_str(result.visibility) == "private",
			created_on = json.safe_str(result.created_at) or "",
			readme = nil,
			stars = tonumber(result.star_count) or nil,
			forks = tonumber(result.forks_count) or nil,
			watchers = nil,
		}

		local project_id = tonumber(result.id)
		local default_branch = details.default_branch or ""
		if project_id == nil or default_branch == "" then
			on_done(details, nil)
			return
		end

		local readme_path = configured_readme_path(repo)
		local readme_endpoint = string.format(
			"/projects/%d/repository/files/%s/raw?ref=%s",
			project_id,
			service.url_encode(readme_path),
			service.url_encode(default_branch)
		)
		requests.run(function(done)
			return service.request_text("GET", readme_endpoint, done, {
				action = "Fetch repository README",
				repo = path,
				path = readme_path,
			})
		end, function(body, _)
			if body and body ~= "" then
				details.readme = body
			end
			on_done(details, nil)
		end)
	end)
	return requests
end

---@param repo AtlasRepository
---@param opts { cursor?: string, search?: string }
---@param on_done fun(branches: AtlasRepositoryBranches|nil, err: string|nil, next_cursor: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_branches(repo, opts, on_done)
	opts = opts or {}
	local path = repo_path(repo)
	if path == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local page = math.max(1, math.floor(tonumber(opts.cursor) or 1))
	local endpoint =
		string.format("/projects/%s/repository/branches?per_page=100&page=%d", service.url_encode(path), page)
	if opts.search and opts.search ~= "" then
		endpoint = endpoint .. "&search=" .. service.url_encode(opts.search)
	end

	return service.request("GET", endpoint, nil, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Invalid paginated response")
			return
		end
		---@type AtlasRepositoryBranches
		local branches = { entries = {} }
		for _, branch_value in ipairs(result) do
			local branch = json.safe_table(branch_value)
			local commit = json.safe_table(branch.commit)
			---@type AtlasRepositoryBranch
			local entry = {
				name = json.safe_str(branch.name) or "",
				hash = json.safe_str(commit.id) or "",
				date = json.safe_str(commit.committed_date) or "",
				message = json.safe_str(commit.message) or json.safe_str(commit.title) or "",
				author = json.safe_str(commit.author_name) or "",
			}
			if type(branch.protected) == "boolean" then
				entry.protected = branch.protected
			end
			table.insert(branches.entries, entry)
		end
		local next_cursor = #result == 100 and tostring(page + 1) or nil
		on_done(branches, nil, next_cursor)
	end, {
		action = "Fetch repository branches",
		repo = path,
	})
end

---@param repo AtlasRepository
---@param opts { cursor?: string, search?: string }
---@param on_done fun(tags: AtlasRepositoryTag[]|nil, err: string|nil, next_cursor: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_tags(repo, opts, on_done)
	opts = opts or {}
	local path = repo_path(repo)
	if path == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local page = math.max(1, math.floor(tonumber(opts.cursor) or 1))
	local endpoint = string.format("/projects/%s/repository/tags?per_page=100&page=%d", service.url_encode(path), page)
	if opts.search and opts.search ~= "" then
		endpoint = endpoint .. "&search=" .. service.url_encode(opts.search)
	end

	return service.request("GET", endpoint, nil, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Invalid paginated response")
			return
		end
		---@type AtlasRepositoryTag[]
		local entries = {}
		for _, tag_value in ipairs(result) do
			local tag = json.safe_table(tag_value)
			local commit = json.safe_table(tag.commit)
			local name = json.safe_str(tag.name) or ""
			local browser_url = repo.html_url or ""
			local annotation = json.safe_str(tag.message)
			if annotation == "" then
				annotation = nil
			end
			table.insert(entries, {
				name = name,
				hash = json.safe_str(commit.id) or "",
				tag_date = json.safe_str(tag.created_at),
				description = annotation,
				message = annotation or json.safe_str(commit.message) or json.safe_str(commit.title),
				author = json.safe_str(commit.author_name),
				url = browser_url ~= "" and browser_url .. "/-/tags/" .. service.url_encode(name) or nil,
			})
		end
		local next_cursor = #result == 100 and tostring(page + 1) or nil
		on_done(entries, nil, next_cursor)
	end, {
		action = "Fetch repository tags",
		repo = path,
	})
end

---@param repo AtlasRepository
---@param on_done fun(releases: AtlasRepositoryRelease[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_releases(repo, on_done)
	local path = tostring(repo.full_name or "")
	if path == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local requests = request_scope.new()
	---@type AtlasRepositoryRelease[]
	local entries = {}
	local function fetch_page(cursor)
		requests.run(function(done)
			return service.graphql(RELEASES_QUERY, { path = path, cursor = cursor }, done, {
				action = "Fetch repository releases",
				repo = path,
			})
		end, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			local project = json.nilify(json.safe_table(result).project)
			if project == nil then
				on_done(nil, "Repository not found")
				return
			end
			local releases = json.safe_table(project.releases)
			for _, release in ipairs(json.safe_table(releases.nodes)) do
				local links = json.safe_table(release.links)
				local tag = json.safe_str(release.tagName) or ""
				local name = json.safe_str(release.name)
				local browser_url = repo.html_url or ""
				table.insert(entries, {
					id = tag,
					name = name and name ~= "" and name or tag,
					tag = tag,
					url = json.safe_str(links.selfUrl)
						or (browser_url ~= "" and browser_url .. "/-/releases/" .. service.url_encode(tag) or ""),
					published_at = json.safe_str(release.releasedAt),
				})
			end

			local page_info = json.safe_table(releases.pageInfo)
			if page_info.hasNextPage then
				fetch_page(page_info.endCursor)
				return
			end
			on_done(entries, nil)
		end)
	end
	fetch_page(nil)
	return requests
end

---@param repo AtlasRepository
---@param opts { id?: string }
---@param on_done fun(release: AtlasRepositoryReleaseDetails|nil, err: string|nil, status?: integer)
---@return { cancel: fun() }|nil
function M.fetch_release(repo, opts, on_done)
	opts = opts or {}
	local path = repo_path(repo)
	if path == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local release_path = opts.id and service.url_encode(opts.id) or "permalink/latest"
	local endpoint = string.format("/projects/%s/releases/%s", service.url_encode(path), release_path)
	return service.request("GET", endpoint, nil, function(result, err, status)
		if err then
			on_done(nil, err, status)
			return
		end
		if json.nilify(result) == nil then
			on_done(nil, nil, status)
			return
		end
		local release = json.safe_table(result)
		local author = json.safe_table(release.author)
		local links = json.safe_table(release._links)
		local release_assets = json.safe_table(release.assets)
		local tag = json.safe_str(release.tag_name) or ""
		local name = json.safe_str(release.name)
		local browser_url = repo.html_url or ""
		---@type AtlasRepositoryReleaseAsset[]
		local assets = {}
		for _, asset in ipairs(json.safe_table(release_assets.links)) do
			table.insert(assets, {
				name = json.safe_str(asset.name) or "",
				url = json.safe_str(asset.direct_asset_url) or json.safe_str(asset.url) or "",
			})
		end
		for _, source in ipairs(json.safe_table(release_assets.sources)) do
			table.insert(assets, {
				name = "Source code (" .. (json.safe_str(source.format) or "archive") .. ")",
				url = json.safe_str(source.url) or "",
			})
		end

		---@type AtlasRepositoryReleaseDetails
		local details = {
			id = tag,
			name = name and name ~= "" and name or tag,
			tag = tag,
			description = json.safe_str(release.description) or "",
			url = json.safe_str(links.self)
				or (browser_url ~= "" and browser_url .. "/-/releases/" .. service.url_encode(tag) or ""),
			author = json.safe_str(author.username) or json.safe_str(author.name),
			published_at = json.safe_str(release.released_at),
			assets = assets,
		}
		on_done(details, nil, status)
	end, {
		action = "Fetch repository release",
		repo = path,
		id = opts.id,
	})
end

---@param repo AtlasRepository
---@param on_done fun(summary: AtlasRepositoryIssueSummary|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue_summary(repo, on_done)
	local path = repo.full_name
	if path == "" then
		on_done(nil, "Missing repository info")
		return nil
	end

	-- dueBefore is inclusive, so exclude issues due today.
	local variables = { path = path, overdueBefore = os.date("!%Y-%m-%dT23:59:59Z", os.time() - 86400) }
	return service.graphql(ISSUE_SUMMARY_QUERY, variables, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch repository issue summary")
			return
		end

		local project = json.nilify(result.project)
		if project == nil then
			on_done(nil, "Repository not found")
			return
		end
		local counts = json.safe_table(project.issueStatusCounts)
		local open_count = tonumber(counts.opened)
		local closed_count = tonumber(counts.closed)
		if open_count == nil or closed_count == nil then
			on_done(nil, "Invalid repository issue summary")
			return
		end

		local items = {}
		for _, item in ipairs({
			{ label = "Open unassigned", value = tonumber(json.safe_table(project.unassigned).opened) },
			{ label = "Open overdue", value = tonumber(json.safe_table(project.overdue).opened) },
			{ label = "Labels", value = tonumber(json.safe_table(project.labels).count) },
		}) do
			if item.value ~= nil then
				table.insert(items, item)
			end
		end
		on_done({ open = open_count, closed = closed_count, items = items }, nil)
	end, {
		action = "Fetch repository issue summary",
		repo = path,
	})
end

---@param repo AtlasRepository
---@param state "open"|"closed"
---@param on_done fun(result: { entries: PullsRepoIssue[], counts: { open: integer, closed: integer }|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issues(repo, state, on_done)
	local path = repo_path(repo)
	if path == "" then
		on_done(nil, "Missing repository info")
		return nil
	end

	local project = service.url_encode(path)
	local api_state = state == "open" and "opened" or "closed"
	local requests = request_scope.new()
	requests.all({
		issues = function(done)
			local endpoint = string.format(
				"/projects/%s/issues?state=%s&per_page=50&order_by=created_at&sort=desc",
				project,
				api_state
			)
			return service.request("GET", endpoint, nil, done, {
				action = "Fetch repository issues",
				repo = path,
				state = state,
			})
		end,
		statistics = function(done)
			local endpoint = string.format("/projects/%s/issues_statistics", project)
			return service.request("GET", endpoint, nil, done, {
				action = "Fetch repository issue statistics",
				repo = path,
			})
		end,
	}, function(results, errors)
		if errors.issues then
			on_done(nil, errors.issues)
			return
		end

		local entries = {}
		for _, raw_value in ipairs(json.safe_table(results.issues)) do
			local raw = json.safe_table(raw_value)
			local author = json.safe_table(raw.author)
			table.insert(entries, {
				number = raw.iid,
				title = json.safe_str(raw.title) or "",
				state = (json.safe_str(raw.state) or ""):lower() == "closed" and "closed" or "open",
				author = json.safe_str(author.username) or json.safe_str(author.name) or "",
				created_at = json.safe_str(raw.created_at) or "",
				comments = tonumber(raw.user_notes_count) or 0,
				url = json.safe_str(raw.web_url) or "",
			})
		end

		local counts
		local statistics = json.nilify(results.statistics)
		if statistics then
			local raw_counts = json.safe_table(json.safe_table(statistics.statistics).counts)
			counts = {
				open = tonumber(raw_counts.opened) or 0,
				closed = tonumber(raw_counts.closed) or 0,
			}
		end

		on_done({ entries = entries, counts = counts }, nil)
	end)
	return requests
end

---@param repo AtlasRepository
---@param branch AtlasRepositoryBranch
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_branch(repo, branch, on_done)
	local path = repo_path(repo)
	local name = tostring(branch.name or "")
	if path == "" or name == "" then
		vim.schedule(function()
			on_done(false, "Missing branch info")
		end)
		return nil
	end

	local endpoint =
		string.format("/projects/%s/repository/branches/%s", service.url_encode(path), service.url_encode(name))
	return service.request("DELETE", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end, {
		action = "Delete repository branch",
		repo = path,
		branch = name,
	})
end

return M
