local M = {}

local api_utils = require("atlas.core.utils")
local as_table = api_utils.as_table
local service = require("atlas.pulls.providers.bitbucket.api.service")

---@param bb_state any
---@return "open"|"merged"|"declined"|"draft"
local function map_state(bb_state)
	local s = tostring(bb_state or ""):upper()
	if s == "OPEN" then
		return "open"
	elseif s == "MERGED" then
		return "merged"
	elseif s == "DECLINED" or s == "SUPERSEDED" then
		return "declined"
	elseif s == "DRAFT" then
		return "draft"
	end
	return "open"
end

---@param epoch_ms any
---@return string  ISO-8601 string (empty if input missing)
local function from_epoch_ms(epoch_ms)
	local n = tonumber(epoch_ms)
	if n == nil then
		return ""
	end
	return tostring(os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(n / 1000)))
end

---@param links table|nil
---@return string  best-effort web URL for the PR
local function self_html(links)
	local l = as_table(links) or {}
	local self_links = as_table(l.self)
	if type(self_links) == "table" and type(self_links[1]) == "table" then
		return tostring(self_links[1].href or "")
	end
	return ""
end

---@param ref table|nil  Server's fromRef / toRef
---@return { branch: string, commit_hash: string }
local function map_ref(ref)
	local r = as_table(ref) or {}
	return {
		branch = tostring(r.displayId or r.id or ""),
		commit_hash = tostring(r.latestCommit or ""),
	}
end

---@param author table|nil  Server's author object: { user = { name, displayName, ... }, role, approved }
---@return PullsAuthor
local function map_author(author)
	local a = as_table(author) or {}
	local user = as_table(a.user) or {}
	local login = tostring(user.name or "")
	local display = tostring(user.displayName or login or "Unknown")
	return {
		name = display,
		id = tostring(user.id or ""),
		username = login,
		nickname = login,
	}
end

---@param raw table  one entry from values[]
---@param workspace string
---@param repo string
---@return PullRequest
local function to_pull_request(raw, workspace, repo)
	local repo_full_name = string.format("%s/%s", workspace, repo)
	local properties = as_table(raw.properties) or {}

	local pr_base = string.format("/projects/%s/repos/%s/pull-requests/%s", workspace, repo, tostring(raw.id))
	local current_user = select(1, service.get_auth())
	raw.links = as_table(raw.links) or {}
	raw.links.approve = service.url(pr_base .. "/approve")
	raw.links.merge = service.url(pr_base .. "/merge?version=" .. tostring(raw.version or 0))
	if current_user and current_user ~= "" then
		raw.links.request_changes = service.url(pr_base .. "/participants/" .. current_user)
	end

	return {
		id = raw.id,
		title = tostring(raw.title or ""),
		description = tostring(raw.description or ""),
		state = map_state(raw.state),
		author = map_author(raw.author),
		source = map_ref(raw.fromRef),
		destination = map_ref(raw.toRef),
		comments_count = tonumber(properties.commentCount) or 0,
		tasks_count = tonumber(properties.openTaskCount) or 0,
		created_on = from_epoch_ms(raw.createdDate),
		updated_on = from_epoch_ms(raw.updatedDate),
		link = { html = self_html(raw.links) },
		provider = "bitbucket",
		workspace = workspace,
		repo = repo,
		repo_full_name = repo_full_name,
		_raw = raw,
	}
end

---@param result table|nil
---@param workspace string
---@param repo string
---@return PullRequest[]
function M.to_pull_requests_list(result, workspace, repo)
	local payload = as_table(result) or {}
	local out = {}
	for _, item in ipairs(payload.values or {}) do
		local pr = as_table(item)
		if pr ~= nil then
			table.insert(out, to_pull_request(pr, workspace, repo))
		end
	end
	return out
end

---@param user table|nil  Server user: { name, displayName, id, slug }
---@return PullsAuthor
local function actor(user)
	local u = as_table(user) or {}
	local login = tostring(u.name or u.slug or "")
	return {
		name = tostring(u.displayName or login or "Unknown"),
		nickname = login,
		id = tostring(u.id or ""),
	}
end

---@param entry table  one /activities entry
---@return string  human-readable label
local function activity_label(entry)
	local action = tostring(entry.action or ""):upper()
	if action == "COMMENTED" then
		local sub = tostring(entry.commentAction or ""):upper()
		if sub == "EDITED" then
			return "edited a comment"
		elseif sub == "DELETED" then
			return "deleted a comment"
		elseif sub == "REPLIED" then
			return "replied"
		end
		return "commented"
	elseif action == "APPROVED" then
		return "approved"
	elseif action == "UNAPPROVED" then
		return "removed approval"
	elseif action == "REVIEWED" then
		return "requested changes"
	elseif action == "OPENED" then
		return "opened"
	elseif action == "DECLINED" then
		return "declined"
	elseif action == "MERGED" then
		return "merged"
	elseif action == "REOPENED" then
		return "reopened"
	elseif action == "RESCOPED" then
		return "updated source branch"
	end
	return action:lower()
end

---@param action string
---@return string  PullsActivityEntry.kind
local function activity_kind(action)
	local a = tostring(action or ""):upper()
	if a == "COMMENTED" then
		return "comment"
	elseif a == "APPROVED" or a == "UNAPPROVED" or a == "REVIEWED" then
		return "approval"
	end
	return "update"
end

---@param result table|nil
---@return PullsActivityEntry[]
function M.to_activities_list(result)
	local payload = as_table(result) or {}
	local entries = {}

	for _, item in ipairs(payload.values or {}) do
		local entry = as_table(item) or {}
		local action = tostring(entry.action or ""):upper()
		local comment = as_table(entry.comment)
		local body
		local deleted = false
		if action == "COMMENTED" and comment ~= nil then
			body = tostring(comment.text or "")
			if body == "" then
				body = nil
			end
			deleted = tostring(entry.commentAction or ""):upper() == "DELETED"
		end

		table.insert(entries, {
			kind = activity_kind(action),
			date = from_epoch_ms(entry.createdDate),
			actor = actor(entry.user),
			label = activity_label(entry),
			body = body,
			deleted = deleted or nil,
		})
	end

	return entries
end

---@param raw_type any
---@return string  atlas-internal status
local function map_change_type(raw_type)
	local t = tostring(raw_type or ""):upper()
	if t == "ADD" then
		return "added"
	elseif t == "DELETE" then
		return "deleted"
	elseif t == "RENAME" then
		return "renamed"
	elseif t == "COPY" then
		return "modified"
	end
	return "modified"
end

---@param p table|nil
---@return string
local function path_to_string(p)
	local t = as_table(p) or {}
	return tostring(t.toString or t.name or "")
end

---@param result table|nil  /pull-requests/{id}/changes response
---@return PullsDiffstatEntry[]
function M.to_diffstat_list(result)
	local payload = as_table(result) or {}
	local entries = {}
	for _, item in ipairs(payload.values or {}) do
		local d = as_table(item) or {}
		local path = path_to_string(d.path)
		local src_path = d.srcPath ~= nil and path_to_string(d.srcPath) or nil
		table.insert(entries, {
			status = map_change_type(d.type),
			path = path,
			old_path = src_path,
			lines_added = 0,
			lines_removed = 0,
		})
	end
	return entries
end

---@param ts any  unix ms
---@return string  ISO-8601
local function iso(ts)
	return from_epoch_ms(ts)
end

---@param result table|nil  /pull-requests/{id}/commits response
---@return PullsCommit[]
function M.to_commits_list(result)
	local payload = as_table(result) or {}
	local entries = {}
	for _, item in ipairs(payload.values or {}) do
		local c = as_table(item) or {}
		local author = as_table(c.author) or {}
		local hash = tostring(c.id or "")
		local short = tostring(c.displayId or (hash ~= "" and hash:sub(1, 12)) or "")
		table.insert(entries, {
			hash = hash,
			short_hash = short,
			message = tostring(c.message or ""):gsub("\r\n", "\n"):gsub("\n+$", ""),
			author_name = tostring(author.name or "Unknown"),
			author_nickname = tostring(author.emailAddress or ""),
			date = iso(c.authorTimestamp or c.committerTimestamp),
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

---@param raw table|nil
---@param fallback_project string|nil
---@return PullsRepoDetails
function M.to_repo_details(raw, fallback_project)
	raw = as_table(raw) or {}
	local project = as_table(raw.project) or {}
	local links = as_table(raw.links) or {}
	local self_links = as_table(links.self) or {}
	local first_self = as_table(self_links[1]) or {}

	local key = tostring(project.key or fallback_project or "")
	local slug = tostring(raw.slug or "")
	local full_name = (key ~= "" and slug ~= "") and (key .. "/" .. slug) or slug

	if key ~= "" and slug ~= "" then
		raw.links = links
		local repo_base = string.format("/projects/%s/repos/%s", key, slug)
		raw.links.branches = { href = service.url(repo_base .. "/branches") }
		raw.links.tags = { href = service.url(repo_base .. "/tags") }
	end

	return {
		id = full_name ~= "" and full_name or slug,
		name = tostring(raw.name or slug),
		full_name = full_name,
		owner = key,
		repo_name = slug,
		html_url = tostring(first_self.href or ""),
		description = tostring(raw.description or ""),
		size = 0,
		default_branch = "",
		is_private = raw.public ~= true,
		created_on = "",
		readme = nil,
		_raw = raw,
	}
end

return M
