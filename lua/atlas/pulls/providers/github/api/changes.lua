local M = {}

local cli = require("atlas.providers.github.client")
local json = require("atlas.core.json")

local COMMITS_QUERY = [[
query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      commits(first: 100, after: $endCursor) {
        nodes {
          commit {
            oid messageHeadline messageBody authoredDate committedDate
            authors(first: 1) { nodes { name user { login } } }
          }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
]]

---@param pr PullRequest
---@param _ { force_refresh: boolean|nil }|nil
---@param on_done fun(commits: PullsCommit[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commits(pr, _, on_done)
	local repo_slug = pr.repo_full_name or ""
	local owner, repo = repo_slug:match("^([^/]+)/([^/]+)$")
	if not owner then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	return cli.gh({
		"api",
		"graphql",
		"--paginate",
		"--slurp",
		"-f",
		"query=" .. COMMITS_QUERY,
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. repo,
		"-F",
		"number=" .. tostring(pr.id),
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch commits")
			return
		end

		local entries = {}
		for _, page in ipairs(result) do
			local data = json.safe_table(page.data)
			local repository = json.safe_table(data.repository)
			local pull = json.nilify(repository.pullRequest)
			if not pull then
				on_done(nil, "Pull request not found")
				return
			end
			vim.list_extend(entries, pull.commits.nodes)
		end

		local commits = {}
		-- GitHub returns the oldest commit first; our commit lists start with the newest.
		for index = #entries, 1, -1 do
			local raw = entries[index].commit
			local hash = tostring(raw.oid or "")
			local authors = json.safe_table(raw.authors).nodes or {}
			local author_name = ""
			local author_login = ""
			if #authors > 0 then
				author_login = tostring(json.safe_table(authors[1].user).login or "")
				author_name = json.safe_str(authors[1].name) or author_login
			end

			local headline = tostring(raw.messageHeadline or "")
			local body = tostring(raw.messageBody or "")
			local message = body ~= "" and (headline ~= "" and (headline .. "\n\n" .. body) or body) or headline

			table.insert(commits, {
				hash = hash,
				repo_full_name = repo_slug,
				short_hash = #hash > 7 and hash:sub(1, 7) or hash,
				message = message,
				author_name = author_name,
				author_nickname = author_login,
				date = tostring(raw.authoredDate or raw.committedDate or ""),
				html_url = string.format("https://%s/%s/commit/%s", cli.hostname(), repo_slug, hash),
			})
		end

		on_done(commits, nil)
	end, {
		action = "Fetch PR commits",
		repo = repo_slug,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param _ { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diffstat(pr, _, on_done)
	---@cast pr GitHubPullRequest
	on_done({
		{
			status = "modified",
			path = "",
			old_path = nil,
			lines_added = pr.lines_added,
			lines_removed = pr.lines_removed,
		},
	}, nil)
	return nil
end

return M
