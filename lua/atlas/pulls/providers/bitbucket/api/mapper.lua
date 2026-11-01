local M = {}

local json = require("atlas.core.json")
local bitbucket_mapper = require("atlas.providers.bitbucket.mapper")

---@param update table   raw bitbucket update payload
---@return string
local function describe_update(update)
	local changes = json.safe_table(update.changes)
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
			local rev = json.safe_table(changes.reviewers)
			local reviewers = json.safe_table(rev.added)
			local verb = "added"
			if #reviewers == 0 then
				reviewers = json.safe_table(rev.removed)
				verb = "removed"
			end
			if #reviewers == 0 then
				return "updated reviewers"
			end
			local names = {}
			for _, reviewer in ipairs(reviewers) do
				names[#names + 1] = reviewer.display_name or reviewer.nickname or "someone"
			end
			return verb .. " reviewer: " .. table.concat(names, ", ")
		end
	end

	if #keys > 1 then
		return "updated " .. table.concat(keys, ", ")
	end

	local source = json.safe_table(update.source)
	local destination = json.safe_table(update.destination)
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
	local s = tostring(bb_state or ""):upper()
	if s == "MERGED" then
		return "merged"
	elseif s == "DECLINED" or s == "SUPERSEDED" then
		return "declined"
	elseif is_draft then
		return "draft"
	end
	return "open"
end

---@param links table|nil
---@param key string
---@return string
local function link_href(links, key)
	links = json.safe_table(links)
	local link = links[key]
	if link == nil and key == "request_changes" then
		link = links["request-changes"]
	end
	if type(link) == "string" then
		return link
	end
	return tostring(json.safe_table(link).href or "")
end

---@param repository table|nil
---@return string|nil https_url
---@return string|nil ssh_url
local function clone_urls(repository)
	repository = json.safe_table(repository)
	local links = json.safe_table(repository.links)
	local https_url, ssh_url
	for _, raw in ipairs(json.safe_table(links.clone)) do
		local clone = json.safe_table(raw)
		local href = tostring(clone.href or "")
		if clone.name == "https" then
			https_url = href
		elseif clone.name == "ssh" then
			ssh_url = href
		end
	end
	return https_url ~= "" and https_url or nil, ssh_url ~= "" and ssh_url or nil
end

---@param participant table
---@return "approved"|"changes_requested"|nil
local function participant_decision(participant)
	local state = tostring(participant.state or ""):lower()
	if participant.approved == true or state == "approved" then
		return "approved"
	end
	if state == "changes_requested" then
		return "changes_requested"
	end
	return nil
end

---@param participant table
---@param decision "approved"|"changes_requested"|"pending"
---@param role "reviewer"|"participant"
---@return PullsReviewer
local function to_reviewer(participant, decision, role)
	local user = json.safe_table(participant.user)
	local provider_id = tostring(user.uuid or "")
	local username = tostring(user.nickname or user.username or "")
	return {
		id = tostring(user.account_id or user.uuid or user.id or ""),
		provider_id = provider_id ~= "" and provider_id or nil,
		name = tostring(user.display_name or user.name or username),
		username = username,
		decision = decision,
		role = role,
	}
end

---@param participants table[]|nil
---@return PullsReviewer[]
function M.to_reviewers(participants)
	local reviewers = {}
	for _, participant in ipairs(participants or {}) do
		local role = tostring(participant.role or ""):upper()
		local decision = participant_decision(participant)
		if role == "REVIEWER" then
			table.insert(reviewers, to_reviewer(participant, decision or "pending", "reviewer"))
		elseif role == "PARTICIPANT" and decision then
			table.insert(reviewers, to_reviewer(participant, decision, "participant"))
		end
	end
	return reviewers
end

---@param raw table
---@param workspace string
---@param repo string
---@return BitbucketPullRequest
function M.to_pull_request(raw, workspace, repo)
	local author = json.safe_table(raw.author)
	local links = json.safe_table(raw.links)
	local source = json.safe_table(raw.source)
	local destination = json.safe_table(raw.destination)
	local source_repository = json.safe_table(source.repository)
	local destination_repository = json.safe_table(destination.repository)
	local repository = bitbucket_mapper.to_repository(destination_repository, workspace, repo)
	local source_https_url, source_ssh_url = clone_urls(source_repository)
	local destination_https_url, destination_ssh_url = clone_urls(destination_repository)
	local repo_full_name = repository.full_name
	local source_repo_full_name = tostring(source_repository.full_name or "")
	local source_is_fork = source_repo_full_name ~= "" and source_repo_full_name ~= repo_full_name
	local participants = json.nilify(raw.participants)
	local mapped_links = {
		html = link_href(links, "html"),
		self = link_href(links, "self"),
		merge = link_href(links, "merge"),
		decline = link_href(links, "decline"),
		commits = link_href(links, "commits"),
		approve = link_href(links, "approve"),
		request_changes = link_href(links, "request_changes"),
		diffstat = link_href(links, "diffstat"),
		comments = link_href(links, "comments"),
		activity = link_href(links, "activity"),
		statuses = link_href(links, "statuses"),
	}

	return {
		id = tonumber(raw.id) or 0,
		title = tostring(raw.title or ""),
		state = map_state(tostring(raw.state or ""), raw.draft == true),
		author = {
			name = tostring(author.display_name or "Unknown"),
			id = tostring(author.account_id or ""),
			username = tostring(author.nickname or ""),
		},
		source = {
			branch = tostring(json.safe_table(source.branch).name or ""),
			commit_hash = tostring(json.safe_table(source.commit).hash or ""),
			https_url = source_is_fork and (source_https_url or "") or nil,
			ssh_url = source_is_fork and (source_ssh_url or "") or nil,
		},
		destination = {
			branch = tostring(json.safe_table(destination.branch).name or ""),
			commit_hash = tostring(json.safe_table(destination.commit).hash or ""),
			https_url = destination_https_url,
			ssh_url = destination_ssh_url,
		},
		comments_count = tonumber(raw.comment_count) or 0,
		tasks_count = tonumber(raw.task_count) or 0,
		created_on = tostring(raw.created_on or ""),
		updated_on = tostring(raw.updated_on or ""),
		link = { html = mapped_links.html },
		provider = "bitbucket",
		repo = repository,
		repo_full_name = repo_full_name,
		reviewers = participants and M.to_reviewers(participants) or nil,
		links = mapped_links,
	}
end

---@param result table|nil
---@param workspace string|nil
---@param repo string|nil
---@return BitbucketPullRequest[]
function M.to_pull_requests_list(result, workspace, repo)
	local payload = json.safe_table(result)
	local out = {}
	local ws = tostring(workspace or "")
	local rp = tostring(repo or "")

	for _, item in ipairs(payload.values or {}) do
		table.insert(out, M.to_pull_request(item, ws, rp))
	end

	return out
end

---@param user table|nil
---@return AtlasUser
local function actor(user)
	local u = json.safe_table(user)
	local username = tostring(u.nickname or u.username or "")
	return {
		name = tostring(u.display_name or "Unknown"),
		username = username,
		id = tostring(u.account_id or ""),
	}
end

---@param content table
---@return string|nil
local function content_display(content)
	local raw = tostring(content.raw or "")
	local names = {}
	local entities = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

	for _, id, label in
		tostring(content.html or ""):gmatch("<span[^>]-data%-atlassian%-id=(['\"])(.-)%1[^>]*>(.-)</span>")
	do
		local name = label:gsub("<[^>]*>", ""):gsub("&(#?[%w]+);", function(entity)
			local hexadecimal = entity:match("^#x(%x+)$")
			local code = hexadecimal and tonumber(hexadecimal, 16) or tonumber(entity:match("^#(%d+)$"))
			return code and vim.fn.nr2char(code) or entities[entity]
		end)

		if name ~= "" then
			names[id] = name:gsub("([\\`*_~%[%]<>])", "\\%1")
		end
	end

	local display = raw:gsub("@{([^}]+)}", names)
	return display ~= raw and display or nil
end

---@param result table|nil
---@return PullsActivityEntry[]
function M.to_activities_list(result)
	local payload = json.safe_table(result)
	local entries = {}

	for _, item in ipairs(payload.values or {}) do
		local entry = json.safe_table(item)
		local update = json.nilify(entry.update)
		local approval = json.nilify(entry.approval)
		local changes_request = json.nilify(entry.changes_request)
		local comment = json.nilify(entry.comment)

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
		elseif changes_request ~= nil then
			table.insert(entries, {
				kind = "changes_requested",
				date = tostring(changes_request.date or ""),
				actor = actor(changes_request.user),
				label = "requested changes",
			})
		elseif comment ~= nil then
			local content = json.safe_table(comment.content)
			local body = content_display(content) or tostring(content.raw or "")
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
	local payload = json.safe_table(result)
	local entries = {}

	for _, item in ipairs(payload.values or {}) do
		local entry = json.safe_table(item)
		local author_raw = json.safe_table(entry.author)
		local user = json.safe_table(author_raw.user)
		local links = json.safe_table(entry.links)
		local hash = tostring(entry.hash or "")
		local message = tostring(entry.message or ""):gsub("\r\n", "\n"):gsub("\n+$", "")

		table.insert(entries, {
			hash = hash,
			short_hash = (hash ~= "" and hash:sub(1, 12)) or "",
			message = message,
			author_name = tostring(user.display_name or "Unknown"),
			author_nickname = tostring(user.nickname or ""),
			date = tostring(entry.date or ""),
			html_url = tostring(json.safe_table(links.html).href or ""),
			statuses_url = tostring(json.safe_table(links.statuses).href or ""),
		})
	end

	return entries
end

---@param raw_inline table|nil
---@return PullsInlineCommentPosition|nil, PullsFileCommentPosition|nil
local function comment_position(raw_inline)
	local inline = json.nilify(raw_inline)
	if inline == nil then
		return nil, nil
	end
	local path = tostring(inline.path or "")
	local from = tonumber(inline["from"])
	local to = tonumber(inline["to"])
	local start_from = tonumber(inline.start_from)
	local start_to = tonumber(inline.start_to)
	if path == "" then
		return nil, nil
	end
	if from == nil and to == nil then
		return nil, { path = path }
	end
	return { path = path, from = from, to = to, start_from = start_from, start_to = start_to }, nil
end

---@param result table|nil
---@param author_id string|nil
---@return PullsComment|nil
function M.to_comment(result, author_id)
	local entry = json.nilify(result)
	if entry == nil then
		return nil
	end
	local author = actor(entry.user)
	local content = json.safe_table(entry.content)
	local links = json.safe_table(entry.links)
	local parent = json.nilify(entry.parent)
	local resolution = json.nilify(entry.resolution)
	local resolution_user = resolution and json.nilify(resolution.user) or nil
	local raw_inline = json.nilify(entry.inline)
	local is_thread_root = parent == nil
	local outdated = raw_inline ~= nil and raw_inline.outdated == true
	local inline, file = comment_position(raw_inline)
	local state = (resolution ~= nil and "RESOLVED") or (outdated and "OUTDATED") or nil

	return {
		id = tonumber(entry.id) or 0,
		parent_id = parent ~= nil and tonumber(parent.id) or nil,
		author = author,
		author_roles = author.id ~= "" and author.id == author_id and { "Author" } or nil,
		body = tostring(content.raw or ""),
		body_display = content_display(content),
		created_at = tostring(entry.created_on or ""),
		resolved_at = resolution
				and is_thread_root
				and type(resolution.created_on) == "string"
				and resolution.created_on
			or nil,
		resolved_by = resolution_user and is_thread_root and actor(resolution_user) or nil,
		file = file,
		inline = inline,
		pending = entry.pending == true and entry.deleted ~= true,
		state = state,
		deleted = entry.deleted == true,
		outdated = outdated,
		url = tostring(json.safe_table(links.html).href or ""),
	}
end

---@param result table|nil
---@param author_id string|nil
---@return PullsComment[]
function M.to_comments_list(result, author_id)
	local payload = json.safe_table(result)
	local entries = {}

	for _, item in ipairs(payload.values or {}) do
		local entry = M.to_comment(item, author_id)
		if entry ~= nil then
			table.insert(entries, entry)
		end
	end

	return entries
end

---@param result table|nil
---@param author_id string|nil
---@return PullsComment[]
function M.to_tasks_list(result, author_id)
	local payload = json.safe_table(result)
	local entries = {}

	for _, item in ipairs(payload.values or {}) do
		local task = json.safe_table(item)
		local content = json.safe_table(task.content)
		local links = json.safe_table(task.links)
		local comment = json.nilify(task.comment)
		local resolved_by = json.nilify(task.resolved_by)
		local author = actor(task.creator)

		table.insert(entries, {
			id = tonumber(task.id) or 0,
			parent_id = comment ~= nil and tonumber(comment.id) or nil,
			author = author,
			author_roles = author.id ~= "" and author.id == author_id and { "Author" } or nil,
			body = tostring(content.raw or ""),
			body_display = content_display(content),
			created_at = tostring(task.created_on or ""),
			resolved_at = type(task.resolved_on) == "string" and task.resolved_on or nil,
			resolved_by = resolved_by and actor(resolved_by) or nil,
			is_task = true,
			pending = task.pending == true,
			state = tostring(task.state or "") == "RESOLVED" and "RESOLVED" or nil,
			url = tostring(json.safe_table(links.html).href or ""),
		})
	end

	return entries
end

return M
