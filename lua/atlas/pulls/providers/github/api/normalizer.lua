local M = {}

---@param raw table
---@return PullRequest
function M.normalize_pr(raw)
	local author_login = ""
	local author_name = ""
	local author_id = ""
	if type(raw.author) == "table" then
		author_login = tostring(raw.author.login or "")
		local raw_name = raw.author.name
		local name = (raw_name ~= nil and raw_name ~= vim.NIL) and tostring(raw_name) or ""
		author_name = name ~= "" and name or author_login
		author_id = tostring(raw.author.id or "")
	end

	local state = "open"
	local raw_state = tostring(raw.state or ""):upper()
	if raw_state == "MERGED" then
		state = "merged"
	elseif raw_state == "CLOSED" then
		state = "declined"
	elseif raw.isDraft == true then
		state = "draft"
	end

	local repo_name = ""
	local owner = ""
	local repo_full_name = ""
	if type(raw.repository) == "table" then
		repo_name = tostring(raw.repository.name or "")
		repo_full_name = tostring(raw.repository.nameWithOwner or "")
		local parts = vim.split(repo_full_name, "/", { plain = true })
		owner = parts[1] or ""
	end

	return {
		id = tostring(raw.number or ""),
		title = tostring(raw.title or ""),
		description = tostring(raw.body or ""),
		state = state,
		author = {
			name = author_name,
			id = author_id,
			username = author_login,
			nickname = author_login,
		},
		source = {
			branch = tostring(raw.headRefName or ""),
			commit_hash = tostring(raw.headRefOid or ""),
		},
		destination = {
			branch = tostring(raw.baseRefName or ""),
			commit_hash = tostring(raw.baseRefOid or ""),
		},
		comments_count = tonumber(raw.commentsCount)
			or (type(raw.comments) == "table" and tonumber(raw.comments.totalCount))
			or (type(raw.comments) == "table" and #raw.comments)
			or tonumber(raw.comments)
			or 0,
		tasks_count = 0,
		created_on = tostring(raw.createdAt or ""),
		updated_on = tostring(raw.updatedAt or ""),
		link = {
			html = tostring(raw.url or ""),
		},
		provider = "github",
		workspace = owner,
		repo = repo_name,
		repo_full_name = repo_full_name,
		_raw = raw,
	}
end

---@param raw table (search/issues API item)
---@return PullRequest
function M.normalize_search_item(raw)
	local user = raw.user or {}
	local login = tostring(user.login or "")

	local state = "open"
	local raw_state = tostring(raw.state or ""):lower()
	local pr_info = raw.pull_request or {}
	if pr_info.merged_at and pr_info.merged_at ~= vim.NIL then
		state = "merged"
	elseif raw_state == "closed" then
		state = "declined"
	elseif raw.draft == true then
		state = "draft"
	end

	local owner = ""
	local repo_name = ""
	local repo_full_name = ""
	local repo_url = tostring(raw.repository_url or "")
	local o, r = repo_url:match("/repos/([^/]+)/([^/]+)$")
	if o and r then
		owner = o
		repo_name = r
		repo_full_name = owner .. "/" .. repo_name
	end

	return {
		id = tostring(raw.number or ""),
		title = tostring(raw.title or ""),
		description = tostring(raw.body or ""),
		state = state,
		author = {
			name = login,
			id = tostring(user.id or ""),
			username = login,
			nickname = login,
		},
		source = { branch = "", commit_hash = "" },
		destination = { branch = "", commit_hash = "" },
		comments_count = tonumber(raw.comments) or 0,
		tasks_count = 0,
		created_on = tostring(raw.created_at or ""),
		updated_on = tostring(raw.updated_at or ""),
		link = { html = tostring(pr_info.html_url or raw.html_url or "") },
		provider = "github",
		workspace = owner,
		repo = repo_name,
		repo_full_name = repo_full_name,
		_raw = raw,
	}
end

---@param items table[]
---@return PullRequest[]
function M.normalize_search_results(items)
	local out = {}
	for _, raw in ipairs(items or {}) do
		table.insert(out, M.normalize_search_item(raw))
	end
	return out
end

---@param raw_prs table[]
---@return PullRequest[]
function M.normalize_prs(raw_prs)
	local out = {}
	for _, raw in ipairs(raw_prs or {}) do
		table.insert(out, M.normalize_pr(raw))
	end
	return out
end

---@param prs PullRequest[]
---@return PullsGroup[]
function M.group_by_repo(prs)
	local by_repo = {}
	local ordered = {}

	for _, pr in ipairs(prs or {}) do
		local rid = pr.repo_full_name or ""
		local group = by_repo[rid]
		if group == nil then
			group = {
				repo = {
					id = rid,
					name = pr.repo_full_name or rid,
					owner = pr.workspace,
					repo_name = pr.repo,
				},
				prs = {},
			}
			by_repo[rid] = group
			table.insert(ordered, group)
		end
		table.insert(group.prs, pr)
	end

	return ordered
end

---@param raw table
---@return PullsUser
function M.normalize_user(raw)
	return {
		name = tostring(raw.name or raw.login or ""),
		id = tostring(raw.id or ""),
		username = tostring(raw.login or ""),
	}
end

---@param nodes table[]
---@return PullRequest[]
function M.normalize_graphql_search_results(nodes)
	local out = {}
	for _, raw in ipairs(nodes or {}) do
		if raw.number ~= nil then
			table.insert(out, M.normalize_pr(raw))
		end
	end
	return out
end

return M
