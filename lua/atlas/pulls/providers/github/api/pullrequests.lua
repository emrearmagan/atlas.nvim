local M = {}

local cli = require("atlas.providers.github.client")
local mapper = require("atlas.pulls.providers.github.api.mapper")
local memory_cache = require("atlas.core.memory_cache")
local json = require("atlas.core.json")

local GET_PR_GQL = [[
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    name nameWithOwner url sshUrl
    pullRequest(number: $number) {
      id number title state isDraft viewerSubscription reviewDecision
      createdAt updatedAt url body
      reactionGroups { content reactors { totalCount } }
      additions deletions
      labels(first: 10) { nodes { name color } }
      reviews(last: 100) {
        nodes { state author { login ... on User { id name } } }
      }
      reviewRequests(first: 100) {
        nodes {
          requestedReviewer {
            ... on User { id login name }
            ... on Bot { id login }
            ... on Mannequin { id login name }
            ... on Team { id name slug organization { login } }
            ... on EnterpriseTeam { id name slug combinedSlug }
          }
        }
      }
      reviewRequestEvents: timelineItems(last: 100, itemTypes: [REVIEW_REQUESTED_EVENT]) {
        nodes {
          ... on ReviewRequestedEvent {
            requestedReviewer {
              ... on User { id login name }
              ... on Bot { id login }
              ... on Mannequin { id login name }
              ... on Team { id name slug organization { login } }
              ... on EnterpriseTeam { id name slug combinedSlug }
            }
          }
        }
      }
      assignees(first: 10) { nodes { id login name } }
      author { login ... on User { name } }
      headRefName baseRefName headRefOid baseRefOid
      totalCommentsCount
      commits(last: 1) {
        nodes { commit { statusCheckRollup { state } } }
      }
    }
  }
}
]]

local PULL_REQUEST_FIELDS_GQL = [[
fragment PullRequestFields on PullRequest {
  id number title state isDraft reviewDecision
  createdAt updatedAt url
  additions deletions
  author { login ... on User { name } }
  headRefName baseRefName headRefOid baseRefOid
  totalCommentsCount
  repository { name nameWithOwner url sshUrl }
  commits(last: 1) {
    nodes { commit { statusCheckRollup { state } } }
  }
}
]]

local SEARCH_GQL = [[
query($search: String!, $limit: Int!) {
  search(query: $search, type: ISSUE, first: $limit) {
    nodes {
      ... on PullRequest { ...PullRequestFields }
    }
  }
}
]] .. PULL_REQUEST_FIELDS_GQL

---@param search string
---@param on_done fun(pulls: PullRequest[], err: string[]|nil)
---@param opts { force_load?: boolean, limit?: number }|nil
---@return { cancel: fun() }|nil
function M.search_prs(search, on_done, opts)
	opts = opts or {}
	local limit = math.max(1, tonumber(opts.limit) or 50)
	local cache_key = string.format("github:pulls:search:%s:limit:%d", search, limit)

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
		"search=" .. search,
		"-F",
		"limit=" .. tostring(limit),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done({}, { err or "Failed to search pull requests" })
			return
		end

		local prs = mapper.to_search_results_from_graphql(result.data.search.nodes or {})
		cli.set_cache(cache_key, prs)
		on_done(prs, nil)
	end, {
		action = "Search PRs",
		search = search,
		limit = limit,
	})
end

---@param refs PullRequestRef[]
---@param on_done fun(pulls: PullRequest[], err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_by_refs(refs, on_done)
	if #refs == 0 then
		on_done({}, nil)
		return nil
	end

	local variables = {}
	local selections = {}
	local args = { "api", "graphql" }
	for index, ref in ipairs(refs) do
		local owner, repo = ref.repo_full_name:match("^([^/]+)/(.+)$")
		if owner == nil or repo == nil then
			on_done({}, "Missing repository info")
			return nil
		end
		table.insert(variables, string.format("$owner%d: String!", index))
		table.insert(variables, string.format("$repo%d: String!", index))
		table.insert(variables, string.format("$number%d: Int!", index))
		table.insert(
			selections,
			string.format(
				"  item%d: repository(owner: $owner%d, name: $repo%d) { pullRequest(number: $number%d) { ...PullRequestFields } }",
				index,
				index,
				index,
				index
			)
		)
		table.insert(args, "-f")
		table.insert(args, string.format("owner%d=%s", index, owner))
		table.insert(args, "-f")
		table.insert(args, string.format("repo%d=%s", index, repo))
		table.insert(args, "-F")
		table.insert(args, string.format("number%d=%s", index, tostring(ref.id)))
	end

	local query = string.format(
		"query(%s) {\n%s\n}\n%s",
		table.concat(variables, ", "),
		table.concat(selections, "\n"),
		PULL_REQUEST_FIELDS_GQL
	)
	table.insert(args, "-f")
	table.insert(args, "query=" .. query)

	return cli.gh(args, function(result, err)
		if err or type(result) ~= "table" then
			on_done({}, err or "Failed to fetch pull requests")
			return
		end

		local nodes = {}
		for index = 1, #refs do
			local repository = result.data["item" .. index]
			if type(repository) == "table" and type(repository.pullRequest) == "table" then
				table.insert(nodes, repository.pullRequest)
			end
		end
		on_done(mapper.to_search_results_from_graphql(nodes), nil)
	end, {
		action = "Fetch PRs by refs",
		count = #refs,
	})
end

---@param owner string
---@param repo string
---@param number number|string
---@param on_done fun(pr: PullRequestDetails|nil, err: string|nil)
---@param opts { force_load?: boolean }|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.get_pr(owner, repo, number, on_done, opts)
	opts = opts or {}
	local repo_slug = string.format("%s/%s", owner, repo)
	local cache_key = string.format("github:pr:%s:%s", repo_slug, tostring(number))

	if not opts.force_load then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"api",
		"graphql",
		"-f",
		"query=" .. vim.trim(GET_PR_GQL),
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. repo,
		"-F",
		"number=" .. tostring(number),
	}, function(result, err)
		if err or not result or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch PR")
			return
		end

		local repository = json.nilify(result.data.repository)
		local pr_raw = repository and json.nilify(repository.pullRequest)
		if not pr_raw then
			on_done(nil, "PR not found")
			return
		end

		pr_raw.repository = {
			name = repository.name or repo,
			nameWithOwner = repository.nameWithOwner or repo_slug,
			url = repository.url,
			sshUrl = repository.sshUrl,
		}
		local pr = mapper.to_pull_request_details(pr_raw)
		cli.set_mem(cache_key, pr, cli.cache_ttl())
		on_done(pr, nil)
	end, {
		action = "Fetch PR",
		repo = repo_slug,
		number = number,
	})
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(description: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_description(pr, opts, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = string.format("github:desc:%s:%s", repo_slug, tostring(pr.id))
	opts = opts or {}

	if not opts.force_refresh then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh({
		"pr",
		"view",
		tostring(pr.id),
		"--repo",
		repo_slug,
		"--json",
		"body",
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch description")
			return
		end
		local body = tostring(result.body or "")
		cli.set_mem(cache_key, body)
		on_done(body, nil)
	end, {
		action = "Fetch PR description",
		repo = repo_slug,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param title string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_title(pr, title, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(false, "Missing repo")
		end)
		return nil
	end

	return cli.gh({
		"pr",
		"edit",
		tostring(pr.id),
		"--repo",
		repo_slug,
		"--title",
		title,
	}, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		memory_cache.delete(string.format("github:pr:%s:%s", repo_slug, tostring(pr.id)))
		on_done(true, nil)
	end, {
		action = "Update PR title",
		repo = repo_slug,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param draft boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_draft(pr, draft, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(false, "Missing repo")
		end)
		return nil
	end

	local args = {
		"pr",
		"ready",
		tostring(pr.id),
		"--repo",
		repo_slug,
	}
	if draft then
		table.insert(args, "--undo")
	end

	return cli.gh(args, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		memory_cache.delete(string.format("github:pr:%s:%s", repo_slug, tostring(pr.id)))
		on_done(true, nil)
	end, {
		action = draft and "Convert PR to draft" or "Mark PR ready for review",
		repo = repo_slug,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param description string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_description(pr, description, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(false, "Missing repo")
		end)
		return nil
	end

	return cli.gh({
		"pr",
		"edit",
		tostring(pr.id),
		"--repo",
		repo_slug,
		"--body",
		description,
	}, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		memory_cache.delete(string.format("github:pr:%s:%s", repo_slug, tostring(pr.id)))
		memory_cache.delete(string.format("github:desc:%s:%s", repo_slug, tostring(pr.id)))
		on_done(true, nil)
	end, {
		action = "Update PR description",
		repo = repo_slug,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.decline(pr, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		on_done(false, "Missing repo")
		return nil
	end
	return cli.gh({
		"pr",
		"close",
		tostring(pr.id),
		"--repo",
		repo_slug,
	}, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		memory_cache.delete(string.format("github:pr:%s:%s", repo_slug, tostring(pr.id)))
		on_done(true, nil)
	end, {
		action = "Decline PR",
		repo = repo_slug,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_reviewers(pr, opts, on_done)
	local repo_slug = pr.repo_full_name or ""
	local owner, repo = repo_slug:match("^([^/]+)/([^/]+)$")
	if owner == nil or repo == nil then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	opts = opts or {}
	return M.get_pr(owner, repo, pr.id, function(fresh, err)
		if err or fresh == nil then
			on_done(nil, err or "Failed to fetch reviewers")
			return
		end
		pr.reviewers = fresh.reviewers
		on_done(pr.reviewers or {}, nil)
	end, { force_load = opts.force_refresh == true })
end

---@param opts { repo_slug: string, repo_root: string|nil, head: string, base: string, pr: PullRequest|nil }
---@param on_done fun(reviewers: PullsCreatePRReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_default_reviewers(opts, on_done)
	local slug = tostring(opts.repo_slug or "")
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo slug")
		end)
		return nil
	end

	return cli.gh(
		{ "api", "--paginate", "--slurp", string.format("repos/%s/collaborators?per_page=100", slug) },
		function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Failed to fetch repository collaborators")
				return
			end

			local reviewers = {}
			local by_login = {}
			for _, page in ipairs(result) do
				for _, raw in ipairs(page) do
					local login = tostring(raw.login or "")
					if login ~= "" then
						local reviewer = {
							label = "@" .. login,
							provider_id = login,
							selected = false,
							default = false,
						}
						by_login[login] = reviewer
						table.insert(reviewers, reviewer)
					end
				end
			end

			if not opts.pr then
				on_done(reviewers, nil)
				return
			end
			M.get_reviewers(opts.pr, { force_refresh = true }, function(current, current_err)
				if current_err then
					on_done(nil, current_err)
					return
				end
				for _, item in ipairs(current or {}) do
					if item.role == "reviewer" then
						local login = item.nickname or item.name
						local reviewer = by_login[login]
						if reviewer then
							reviewer.selected = true
						else
							table.insert(reviewers, {
								label = "@" .. login,
								provider_id = login,
								selected = true,
							})
						end
					end
				end
				on_done(reviewers, nil)
			end)
		end,
		{
			action = "Fetch default reviewers",
			repo = slug,
		}
	)
end

---@param pr PullRequest
---@param selected PullsCreatePRReviewer[]
---@param original PullsCreatePRReviewer[]
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_reviewers(pr, selected, original, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(false, "Missing repo")
		end)
		return nil
	end

	local selected_set = {}
	for _, reviewer in ipairs(selected) do
		selected_set[reviewer.provider_id] = true
	end

	local original_set = {}
	for _, reviewer in ipairs(original) do
		original_set[reviewer.provider_id] = true
	end

	local added = {}
	for _, reviewer in ipairs(selected) do
		if not original_set[reviewer.provider_id] then
			table.insert(added, reviewer.provider_id)
		end
	end

	local removed = {}
	for _, reviewer in ipairs(original) do
		if not selected_set[reviewer.provider_id] then
			table.insert(removed, reviewer.provider_id)
		end
	end

	if #added == 0 and #removed == 0 then
		on_done(true, nil)
		return nil
	end

	local args = { "pr", "edit", tostring(pr.id), "--repo", repo_slug }
	for _, login in ipairs(added) do
		table.insert(args, "--add-reviewer")
		table.insert(args, login)
	end
	for _, login in ipairs(removed) do
		table.insert(args, "--remove-reviewer")
		table.insert(args, login)
	end

	return cli.gh(args, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		memory_cache.delete(string.format("github:pr:%s:%s", repo_slug, tostring(pr.id)))
		memory_cache.delete(string.format("github:review-context:%s:%s", repo_slug, tostring(pr.id)))
		memory_cache.delete(string.format("github:review-details:%s:%s", repo_slug, tostring(pr.id)))
		on_done(true, nil)
	end, {
		action = "Update PR reviewers",
		repo = repo_slug,
		number = pr.id,
		added = #added,
		removed = #removed,
	})
end

---@param opts PullsCreatePROpts
---@param on_done fun(result: PullsCreatePRResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_pr(opts, on_done)
	local slug = tostring(opts.repo_slug or "")
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	local args = {
		"pr",
		"create",
		"--repo",
		slug,
		"--head",
		opts.head,
		"--base",
		opts.base,
		"--title",
		opts.title,
		"--body",
		opts.body or "",
	}
	if opts.draft then
		table.insert(args, "--draft")
	end

	for _, reviewer in ipairs(opts.reviewers or {}) do
		table.insert(args, "--reviewer")
		table.insert(args, reviewer.provider_id)
	end

	return cli.gh(args, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		-- gh prints the new PR URL on stdout. result is either a parsed table
		-- (unlikely here) or a string (the URL). Trim and surface it.
		local url = nil
		local id = nil
		if type(result) == "string" then
			url = vim.trim(result)
			-- last segment of /pull/<id>
			id = url:match("/pull/(%d+)")
			if id then
				id = tonumber(id) or id
			end
		end

		on_done({ id = id, url = url, message = "PR created" }, nil)
	end, {
		action = "Create PR",
		slug = slug,
		head = opts.head,
		base = opts.base,
		draft = opts.draft == true,
	})
end

---@param slug string
---@param on_done fun(labels: PullsLabel[]|nil, err: string|nil)
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
					})
				end
			end
		end
		on_done(list, nil)
	end, {
		action = "List labels",
		repo = slug,
	})
end

---@param slug string
---@param number integer|string
---@param diff { add?: string[], remove?: string[] }
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_labels(slug, number, diff, on_done)
	local adds = diff.add or {}
	local removes = diff.remove or {}
	if #adds == 0 and #removes == 0 then
		on_done(true, nil)
		return nil
	end

	local args = { "pr", "edit", tostring(number), "--repo", slug }
	for _, v in ipairs(adds) do
		table.insert(args, "--add-label")
		table.insert(args, tostring(v))
	end
	for _, v in ipairs(removes) do
		table.insert(args, "--remove-label")
		table.insert(args, tostring(v))
	end

	return cli.gh(args, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		on_done(true, nil)
	end, {
		action = "Update PR labels",
		repo = slug,
		number = number,
		added = #adds,
		removed = #removes,
	})
end

return M
