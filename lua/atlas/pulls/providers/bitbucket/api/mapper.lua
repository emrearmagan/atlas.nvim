local M = {}

local api_utils = require("atlas.core.utils")
local as_table = api_utils.as_table

---@param update table   raw bitbucket update payload
---@return string
local function describe_update(update)
	local changes = as_table(update.changes) or {}
	local keys = {}
	for k, _ in pairs(changes) do
		keys[#keys + 1] = k
	end
	table.sort(keys)

	if #keys == 1 then
		local key = keys[1]
		if key == "description" then
			return "updated description"
		end
		if key == "title" then
			return "updated title"
		end
		if key == "draft" then
			local val = changes.draft
			if type(val) == "table" and val.new == false then
				return "marked as ready"
			end
			return "marked as draft"
		end
		if key == "reviewers" then
			local rev = as_table(changes.reviewers) or {}
			local added = as_table(rev.added) or {}
			if #added > 0 then
				local names = {}
				for _, r in ipairs(added) do
					names[#names + 1] = r.display_name or r.nickname or "someone"
				end
				return "added reviewer: " .. table.concat(names, ", ")
			end
			local removed = as_table(rev.removed) or {}
			if #removed > 0 then
				local names = {}
				for _, r in ipairs(removed) do
					names[#names + 1] = r.display_name or r.nickname or "someone"
				end
				return "removed reviewer: " .. table.concat(names, ", ")
			end
			return "updated reviewers"
		end
	end

	if #keys > 1 then
		return "updated " .. table.concat(keys, ", ")
	end

	local source = as_table(update.source) or {}
	local destination = as_table(update.destination) or {}
	local src = tostring((source.branch or {}).name or "")
	local dst = tostring((destination.branch or {}).name or "")
	if src ~= "" and dst ~= "" then
		return string.format("updated %s → %s", src, dst)
	end

	return "updated pull request"
end

---@param bb_state string
---@param is_draft boolean
---@return "open"|"merged"|"declined"|"draft"
local function map_state(bb_state, is_draft)
	if is_draft then
		return "draft"
	end
	local s = tostring(bb_state or ""):upper()
	if s == "OPEN" then
		return "open"
	elseif s == "MERGED" then
		return "merged"
	elseif s == "DECLINED" then
		return "declined"
	end
	return "open"
end

---@param raw table
---@return PullRequest
local function to_pull_request(raw)
	local workspace = tostring(raw.workspace or "")
	local repo = tostring(raw.repo or "")
	local repo_full_name = tostring(raw.repo_full_name or string.format("%s/%s", workspace, repo))
	local author = raw.author or {}
	return {
		id = raw.id,
		title = tostring(raw.title or ""),
		description = tostring(raw.description or ""),
		state = map_state(raw.state, raw.is_draft == true),
		author = {
			name = tostring(author.name or author.display_name or "Unknown"),
			id = tostring(author.account_id or ""),
			username = tostring(author.nickname or ""),
		},
		source = {
			branch = tostring((raw.source or {}).branch or ""),
			commit_hash = tostring((raw.source or {}).commit_hash or ""),
		},
		destination = {
			branch = tostring((raw.destination or {}).branch or ""),
			commit_hash = tostring((raw.destination or {}).commit_hash or ""),
		},
		comments_count = tonumber(raw.comments) or 0,
		tasks_count = tonumber(raw.tasks) or 0,
		created_on = tostring(raw.created_on or ""),
		updated_on = tostring(raw.updated_on or ""),
		link = { html = tostring((raw.links or {}).html or "") },
		provider = "bitbucket",
		workspace = workspace,
		repo = repo,
		repo_full_name = repo_full_name,
		_raw = raw,
	}
end

---@param result table|nil
---@param workspace string|nil
---@param repo string|nil
---@return PullRequest[]
function M.to_pull_requests_list(result, workspace, repo)
	local payload = as_table(result) or {}
	local out = {}
	local ws = tostring(workspace or "")
	local rp = tostring(repo or "")

	for _, item in ipairs(payload.values or {}) do
		local pr = as_table(item) or {}
		local author = as_table(pr.author) or {}
		local links = as_table(pr.links) or {}
		local source = as_table(pr.source) or {}
		local destination = as_table(pr.destination) or {}
		local source_branch = as_table(source.branch) or {}
		local source_commit = as_table(source.commit) or {}
		local destination_branch = as_table(destination.branch) or {}
		local destination_commit = as_table(destination.commit) or {}
		local repo_full_name = (ws ~= "" and rp ~= "") and string.format("%s/%s", ws, rp) or ""

		local raw = {
			id = tonumber(pr.id) or 0,
			title = tostring(pr.title or ""),
			description = tostring(pr.description or ""),
			comments = tonumber(pr.comment_count) or 0,
			tasks = tonumber(pr.task_count) or 0,
			author = {
				name = tostring(author.display_name or ""),
				account_id = tostring(author.account_id or ""),
				nickname = tostring(author.nickname or ""),
			},
			is_draft = pr.draft == true,
			state = tostring(pr.state or ""),
			links = {
				html = tostring((as_table(links.html) or {}).href or ""),
				self = tostring((as_table(links.self) or {}).href or ""),
				merge = tostring((as_table(links.merge) or {}).href or ""),
				commits = tostring((as_table(links.commits) or {}).href or ""),
				approve = tostring((as_table(links.approve) or {}).href or ""),
				request_changes = tostring((as_table(links["request-changes"]) or {}).href or ""),
				diff = tostring((as_table(links.diff) or {}).href or ""),
				diffstat = tostring((as_table(links.diffstat) or {}).href or ""),
				comments = tostring((as_table(links.comments) or {}).href or ""),
				activity = tostring((as_table(links.activity) or {}).href or ""),
				statuses = tostring((as_table(links.statuses) or {}).href or ""),
			},
			destination = {
				branch = tostring(destination_branch.name or ""),
				commit_hash = tostring(destination_commit.hash or ""),
			},
			source = {
				branch = tostring(source_branch.name or ""),
				commit_hash = tostring(source_commit.hash or ""),
			},
			close_source_branch = pr.close_source_branch == true,
			created_on = tostring(pr.created_on or ""),
			updated_on = tostring(pr.updated_on or ""),
			workspace = ws,
			repo = rp,
			repo_full_name = repo_full_name,
		}
		table.insert(out, to_pull_request(raw))
	end

	return out
end

---@param user table|nil
---@return {name: string, nickname: string|nil}
local function actor(user)
	local u = as_table(user) or {}
	return {
		name = tostring(u.display_name or "Unknown"),
		nickname = tostring(u.nickname or ""),
		id = tostring(u.account_id or ""),
	}
end

---@param result table|nil
---@return PullsActivityEntry[]
function M.to_activities_list(result)
	local payload = as_table(result) or {}
	local entries = {}

	for _, item in ipairs(payload.values or {}) do
		local entry = as_table(item) or {}
		local update = as_table(entry.update)
		local approval = as_table(entry.approval)
		local comment = as_table(entry.comment)

		if update ~= nil then
			table.insert(entries, {
				kind = "update",
				date = tostring(update.date or ""),
				actor = actor(update.author),
				label = describe_update(update),
			})
		elseif approval ~= nil then
			table.insert(entries, {
				kind = "approval",
				date = tostring(approval.date or ""),
				actor = actor(approval.user),
				label = "approved",
			})
		elseif comment ~= nil then
			local content = as_table(comment.content) or {}
			local body = tostring(content.raw or "")
			table.insert(entries, {
				kind = "comment",
				date = tostring(comment.created_on or ""),
				actor = actor(comment.user),
				label = "commented",
				body = body ~= "" and body or nil,
				deleted = comment.deleted == true,
			})
		end
	end

	return entries
end

---@param result table|nil
---@return PullsCommit[]
function M.to_commits_list(result)
	local payload = as_table(result) or {}
	local entries = {}

	for _, item in ipairs(payload.values or {}) do
		local entry = as_table(item) or {}
		local author_raw = as_table(entry.author) or {}
		local user = as_table(author_raw.user) or {}
		local links = as_table(entry.links) or {}
		local hash = tostring(entry.hash or "")
		local message = tostring(entry.message or ""):gsub("\r\n", "\n"):gsub("\n+$", "")

		table.insert(entries, {
			hash = hash,
			short_hash = (hash ~= "" and hash:sub(1, 12)) or "",
			message = message,
			author_name = tostring(user.display_name or "Unknown"),
			author_nickname = tostring(user.nickname or ""),
			date = tostring(entry.date or ""),
			html_url = tostring((as_table(links.html) or {}).href or ""),
			statuses_url = tostring((as_table(links.statuses) or {}).href or ""),
		})
	end

	return entries
end

---@param prs PullRequest[]
---@return PullsGroup[]
function M.to_pull_request_groups(prs)
	---@type table<string, PullsGroup>
	local by_repo = {}
	---@type PullsGroup[]
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

---@param raw_inline table|nil
---@return {path: string, to: number|nil, from: number|nil}|nil
local function comment_inline(raw_inline)
	local inline = as_table(raw_inline)
	if inline == nil then
		return nil
	end
	local path = tostring(inline.path or "")
	local from = tonumber(inline["from"])
	local to = tonumber(inline["to"])
	if path == "" and from == nil and to == nil then
		return nil
	end
	return { path = path, ["from"] = from, ["to"] = to }
end

---@param result table|nil
---@return PullsComment|nil
function M.to_comment(result)
	local entry = as_table(result)
	if entry == nil then
		return nil
	end
	local content = as_table(entry.content) or {}
	local links = as_table(entry.links) or {}
	local parent = as_table(entry.parent)

	return {
		id = tonumber(entry.id) or 0,
		parent_id = parent ~= nil and tonumber(parent.id) or nil,
		author = actor(entry.user),
		content_raw = tostring(content.raw or ""),
		created_on = tostring(entry.created_on or ""),
		inline = comment_inline(entry.inline),
		is_task = nil,
		state = entry.deleted == true and "DELETED" or nil,
		url = tostring((as_table(links.self) or {}).href or ""),
		html_url = tostring((as_table(links.html) or {}).href or ""),
		_raw = entry,
	}
end

---@param result table|nil
---@return PullsComment[]
function M.to_comments_list(result)
	local payload = as_table(result) or {}
	local entries = {}

	for _, item in ipairs(payload.values or {}) do
		local entry = M.to_comment(item)
		if entry ~= nil then
			table.insert(entries, entry)
		end
	end

	return entries
end

---@param result table|nil
---@return BitbucketPRTask[]
function M.to_tasks_list(result)
	local payload = as_table(result) or {}
	local entries = {}

	for _, item in ipairs(payload.values or {}) do
		local task = as_table(item) or {}
		local content = as_table(task.content) or {}
		local links = as_table(task.links) or {}
		local comment = as_table(task.comment)
		local comment_links = as_table(comment and comment.links or nil) or {}

		table.insert(entries, {
			id = tonumber(task.id) or 0,
			state = tostring(task.state or ""),
			content_raw = tostring(content.raw or ""),
			created_on = tostring(task.created_on or ""),
			updated_on = tostring(task.updated_on or ""),
			resolved_on = task.resolved_on ~= nil and tostring(task.resolved_on) or nil,
			pending = task.pending == true,
			creator = actor(task.creator),
			comment_id = comment ~= nil and tonumber(comment.id) or nil,
			links = {
				self = tostring((as_table(links.self) or {}).href or ""),
				html = tostring((as_table(links.html) or {}).href or ""),
			},
			comment_html = tostring((as_table(comment_links.html) or {}).href or ""),
		})
	end

	return entries
end

---@param raw table|nil
---@param fallback_workspace string|nil
---@return PullsRepoDetails
function M.to_repo_details(raw, fallback_workspace)
	raw = type(raw) == "table" and raw or {}
	local workspace_obj = type(raw.workspace) == "table" and raw.workspace or {}
	local mainbranch = type(raw.mainbranch) == "table" and raw.mainbranch or {}
	local links = as_table(raw.links) or {}
	local html_link = as_table(links.html) or {}
	local full_name = tostring(raw.full_name or raw.name or raw.slug or "")
	local owner = tostring(workspace_obj.slug or fallback_workspace or "")
	local repo_name = tostring(raw.slug or raw.name or "")

	return {
		id = full_name ~= "" and full_name or repo_name,
		name = tostring(raw.name or repo_name or full_name),
		full_name = full_name,
		owner = owner,
		repo_name = repo_name,
		html_url = tostring(html_link.href or ""),
		description = tostring(raw.description or ""),
		size = tonumber(raw.size) or 0,
		default_branch = tostring(mainbranch.name or ""),
		is_private = raw.is_private == true,
		created_on = tostring(raw.created_on or ""),
		readme = nil,
		_raw = raw,
	}
end

return M
