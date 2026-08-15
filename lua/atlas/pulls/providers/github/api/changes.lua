local M = {}

local cli = require("atlas.providers.github.client").pulls

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(commits: PullsCommit[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commits(pr, opts, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	return cli.gh({
		"pr",
		"view",
		tostring(pr.id),
		"--repo",
		repo_slug,
		"--json",
		"commits",
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch commits")
			return
		end

		local commits = {}
		for _, raw in ipairs(result.commits or {}) do
			local hash = tostring(raw.oid or "")
			local authors = raw.authors or {}
			local author_name = ""
			local author_login = ""
			if #authors > 0 then
				author_name = tostring(authors[1].name or authors[1].login or "")
				author_login = tostring(authors[1].login or "")
			end

			table.insert(commits, {
				hash = hash,
				short_hash = #hash > 7 and hash:sub(1, 7) or hash,
				message = tostring(raw.messageHeadline or raw.messageBody or ""),
				author_name = author_name,
				author_nickname = author_login,
				date = tostring(raw.authoredDate or raw.committedDate or ""),
				html_url = repo_slug ~= "" and string.format("https://github.com/%s/commit/%s", repo_slug, hash) or nil,
			})
		end

		on_done(commits, nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(files: DiffFile[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diff(pr, opts, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	return cli.gh({
		"pr",
		"diff",
		tostring(pr.id),
		"--repo",
		repo_slug,
	}, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local diff_text = tostring(result or "")
		local diff_parser = require("atlas.core.git.diff_parser")
		local files = diff_parser.parse(diff_text)

		on_done(files, nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diffstat(pr, opts, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = string.format("github:diffstat:%s:%s", repo_slug, tostring(pr.id))
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
		"files",
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch files")
			return
		end

		local entries = {}
		for _, file in ipairs(result.files or {}) do
			local additions = tonumber(file.additions) or 0
			local deletions = tonumber(file.deletions) or 0
			local status = "modified"
			if additions > 0 and deletions == 0 then
				status = "added"
			elseif additions == 0 and deletions > 0 then
				status = "removed"
			end
			table.insert(entries, {
				status = status,
				path = tostring(file.path or ""),
				old_path = nil,
				lines_added = additions,
				lines_removed = deletions,
			})
		end

		cli.set_mem(cache_key, entries)
		on_done(entries, nil)
	end, {
		action = "Fetch PR diffstat",
		repo = repo_slug,
		number = pr.id,
	})
end

return M
