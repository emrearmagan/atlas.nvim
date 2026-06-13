local M = {}

-- Map Gitea PR state fields to atlas state
---@param raw table
---@return "open"|"merged"|"declined"|"draft"
local function normalize_state(raw)
	if raw.state == "open" then
		if raw.draft == true then
			return "draft"
		end
		return "open"
	elseif raw.state == "closed" then
		if raw.merged == true then
			return "merged"
		end
		return "declined"
	end
	return "open"
end

-- Gitea PR JSON -> PullRequest
---@param raw table
---@param slug string|nil  e.g. "owner/repo"
---@return PullRequest|nil
function M.to_pull_request(raw, slug)
	if type(raw) ~= "table" then
		return nil
	end
	local number = raw.number
	if number == nil then
		return nil
	end

	local owner = ""
	local repo_name = ""
	local repo_full_name = ""
	if slug and slug ~= "" then
		owner, repo_name = slug:match("^([^/]+)/(.+)$")
		owner = owner or ""
		repo_name = repo_name or ""
		repo_full_name = slug
	elseif type(raw.repository) == "table" then
		local fn = tostring(raw.repository.full_name or "")
		owner, repo_name = fn:match("^([^/]+)/(.+)$")
		owner = owner or ""
		repo_name = repo_name or ""
		repo_full_name = fn
	end

	local user = type(raw.user) == "table" and raw.user or {}
	local full_name = tostring(user.full_name or "")
	local login = tostring(user.login or "")
	local author_name = (full_name ~= "" and full_name or login)

	local head = type(raw.head) == "table" and raw.head or {}
	local base = type(raw.base) == "table" and raw.base or {}

	return {
		id = tostring(number),
		title = tostring(raw.title or ""),
		description = tostring(raw.body or ""),
		state = normalize_state(raw),
		author = {
			name = author_name,
			id = tostring(user.id or ""),
			username = login,
			nickname = login,
		},
		workspace = owner,
		repo = repo_name,
		repo_full_name = repo_full_name,
		link = { html = tostring(raw.html_url or "") },
		source = {
			branch = tostring(head.ref or ""),
			commit_hash = tostring(head.sha or ""),
		},
		destination = {
			branch = tostring(base.ref or ""),
			commit_hash = tostring(base.sha or ""),
		},
		comments_count = tonumber(raw.comments) or 0,
		tasks_count = 0,
		created_on = tostring(raw.created_at or ""),
		updated_on = tostring(raw.updated_at or ""),
		provider = "gitea",
		_raw = raw,
	}
end

-- Group a list of PullRequest objects by repo
---@param raw_list table[]
---@param slug string|nil
---@return PullsGroup[]
function M.to_pull_request_groups(raw_list, slug)
	local by_repo = {}
	local order = {}
	for _, raw in ipairs(raw_list or {}) do
		local pr = M.to_pull_request(raw, slug)
		if pr ~= nil then
			local key = pr.repo_full_name ~= "" and pr.repo_full_name or "unknown"
			if not by_repo[key] then
				by_repo[key] = {
					repo = {
						id = key,
						name = pr.repo,
						owner = pr.workspace,
						repo_name = pr.repo,
						html_url = nil,
					},
					prs = {},
				}
				table.insert(order, key)
			end
			table.insert(by_repo[key].prs, pr)
		end
	end

	local groups = {}
	for _, key in ipairs(order) do
		table.insert(groups, by_repo[key])
	end
	return groups
end

-- Gitea CI status -> PullsBuild
---@param raw table
---@return PullsBuild
function M.to_build(raw)
	local status_map = {
		success = "SUCCESSFUL",
		pending = "INPROGRESS",
		failure = "FAILED",
		error = "FAILED",
		warning = "STOPPED",
	}
	local state = status_map[tostring(raw.status or "")] or "STOPPED"
	local target_url = tostring(raw.target_url or "")
	return {
		key = tostring(raw.id or ""),
		name = tostring(raw.context or "CI"),
		state = state,
		url = target_url ~= "" and target_url or nil,
	}
end

-- Gitea diffstat file -> PullsDiffstatEntry
---@param raw table
---@return PullsDiffstatEntry
function M.to_diffstat_entry(raw)
	local status_map = {
		added = "added",
		removed = "removed",
		changed = "modified",
		renamed = "renamed",
		deleted = "removed",
	}
	return {
		path = tostring(raw.filename or ""),
		status = status_map[tostring(raw.status or "")] or "modified",
		lines_added = tonumber(raw.additions) or 0,
		lines_removed = tonumber(raw.deletions) or 0,
	}
end

-- Gitea commit -> PullsCommit
---@param raw table
---@return PullsCommit
function M.to_commit(raw)
	local author = type(raw.author) == "table" and raw.author or {}
	local commit_data = type(raw.commit) == "table" and raw.commit or {}
	local full_name = tostring(author.full_name or "")
	local login = tostring(author.login or "")
	local hash = tostring(raw.sha or "")
	return {
		hash = hash,
		short_hash = #hash > 7 and hash:sub(1, 7) or hash,
		message = tostring(commit_data.message or raw.message or ""),
		author_name = full_name ~= "" and full_name or login,
		author_nickname = login,
		date = tostring(
			(type(commit_data.author) == "table" and commit_data.author.date)
				or (type(commit_data.committer) == "table" and commit_data.committer.date)
				or ""
		),
		html_url = nil,
	}
end

-- Gitea issue/PR comment -> PullsComment
---@param raw table
---@return PullsComment|nil
function M.to_comment(raw)
	if type(raw) ~= "table" or raw.id == nil then
		return nil
	end
	local user = type(raw.user) == "table" and raw.user or {}
	local full_name = tostring(user.full_name or "")
	local login = tostring(user.login or "")
	return {
		id = tostring(raw.id),
		parent_id = nil,
		content_raw = tostring(raw.body or ""),
		created_on = tostring(raw.created_at or ""),
		author = {
			name = full_name ~= "" and full_name or login,
			nickname = login,
			id = tostring(user.id or ""),
		},
		inline = nil,
		_raw = raw,
	}
end

-- Gitea notification -> AtlasNotification
---@param raw table
---@return AtlasNotification|nil
function M.to_notification(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local subject = type(raw.subject) == "table" and raw.subject or {}
	local repo = type(raw.repository) == "table" and tostring(raw.repository.full_name or "") or ""
	local ntype = tostring(subject.type or "")

	local mapped_type
	if ntype == "PullRequest" then
		mapped_type = "Pull"
	elseif ntype == "Issue" then
		mapped_type = "Issue"
	else
		mapped_type = "Repository"
	end

	local url = tostring(subject.html_url or subject.url or "")
	return {
		id = tostring(raw.id or ""),
		title = tostring(subject.title or ""),
		type = mapped_type,
		url = url ~= "" and url or nil,
		is_unread = raw.unread == true,
		repo = repo ~= "" and repo or nil,
		unread = raw.unread == true,
		subtitle = repo,
		timestamp = tostring(raw.updated_at or "") ~= "" and tostring(raw.updated_at) or nil,
		_raw = raw,
	}
end

-- Gitea user -> PullsUser
---@param raw table
---@return PullsUser|nil
function M.to_user(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local login = tostring(raw.login or "")
	if login == "" then
		return nil
	end
	return {
		name = tostring(raw.full_name ~= "" and raw.full_name or login),
		id = tostring(raw.id or ""),
		username = login,
	}
end

return M
