local M = {}

local json = require("atlas.core.json")
local diff_parser = require("atlas.core.git.diff_parser")

---@param value any
---@return string
local function body_text(value)
	return json.safe_str(value) or ""
end

---@param login string
---@return PullsAuthor|nil
local function actor_from_login(login)
	if login == nil or login == "" then
		return nil
	end
	return { name = login, id = "", username = login, nickname = login }
end

---@param diff_hunk string|nil
---@return DiffHunk|nil
local function parse_diff_hunk(diff_hunk)
	if type(diff_hunk) ~= "string" or diff_hunk == "" then
		return nil
	end
	-- GitHub returns just the @@ snippet but the parser expects a full git-format so we simply wrap it because i am too lazy to rethink this
	local synthetic = "diff --git a/x b/x\n--- a/x\n+++ b/x\n" .. diff_hunk .. "\n"
	local files = diff_parser.parse(synthetic) ---@type DiffFile[]
	if #files == 0 or #files[1].hunks == 0 then
		return nil
	end

	return files[1].hunks[1]
end

---@param raw table
---@return PullRequest
function M.to_pull_request(raw)
	local author_login = ""
	local author_name = ""
	local author_id = ""
	if type(raw.author) == "table" then
		author_login = tostring(raw.author.login or "")
		local name = json.safe_str(raw.author.name) or ""
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
		comments_count = tonumber(raw.commentsCount) or (type(raw.comments) == "table" and tonumber(
			raw.comments.totalCount
		)) or (type(raw.comments) == "table" and #raw.comments) or tonumber(raw.comments) or 0,
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
		is_subscribed = tostring(raw.viewerSubscription or "") == "SUBSCRIBED",
		_raw = raw,
	}
end

---@param raw table (search/issues API item)
---@return PullRequest
function M.to_pull_request_from_search(raw)
	local user = raw.user or {}
	local login = tostring(user.login or "")

	local state = "open"
	local raw_state = tostring(raw.state or ""):lower()
	local pr_info = raw.pull_request or {}
	if json.nilify(pr_info.merged_at) then
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
function M.to_search_results(items)
	local out = {}
	for _, raw in ipairs(items or {}) do
		table.insert(out, M.to_pull_request_from_search(raw))
	end
	return out
end

---@param raw_prs table[]
---@return PullRequest[]
function M.to_pull_requests_list(raw_prs)
	local out = {}
	for _, raw in ipairs(raw_prs or {}) do
		table.insert(out, M.to_pull_request(raw))
	end
	return out
end

---@param prs PullRequest[]
---@return PullsGroup[]
function M.to_pull_request_groups(prs)
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
function M.to_user(raw)
	return {
		name = tostring(raw.name or raw.login or ""),
		id = tostring(raw.id or ""),
		username = tostring(raw.login or ""),
	}
end

---@param nodes table[]
---@return PullRequest[]
function M.to_search_results_from_graphql(nodes)
	local out = {}
	for _, raw in ipairs(nodes or {}) do
		if raw.number ~= nil then
			table.insert(out, M.to_pull_request(raw))
		end
	end
	return out
end

---@param item table
---@return PullsActivityEntry|nil
function M.to_activity(item)
	local event = tostring(item.event or "")
	local actor_login = (type(item.actor) == "table" and tostring(item.actor.login or ""))
		or (type(item.user) == "table" and tostring(item.user.login or ""))
		or ""
	local actor = actor_from_login(actor_login)
	local date = tostring(item.created_at or item.submitted_at or "")

	if event == "commented" then
		local body = body_text(item.body)
		return {
			kind = "comment",
			actor = actor,
			date = date,
			label = "commented",
			body = body ~= "" and body or nil,
		}
	elseif event == "reviewed" then
		local state_label = tostring(item.state or ""):lower()
		local kind = state_label == "approved" and "approval"
			or state_label == "changes_requested" and "changes_requested"
			or "review"
		local verb = kind == "approval" and "approved"
			or kind == "changes_requested" and "requested changes"
			or "left a review"
		local body = body_text(item.body)
		return {
			kind = kind,
			actor = actor,
			date = date,
			label = verb,
			body = body ~= "" and body or nil,
			always_render = body ~= "" or nil,
		}
	elseif event == "closed" or event == "merged" or event == "reopened" then
		return { kind = event, actor = actor, date = date, label = event }
	elseif event == "head_ref_force_pushed" then
		return { kind = "force_pushed", actor = actor, date = date, label = "force pushed" }
	elseif event == "committed" then
		local author = type(item.author) == "table" and item.author or {}
		local author_name = tostring(author.name or "")
		local msg = tostring(item.message or ""):match("([^\n]+)") or ""
		local sha = tostring(item.sha or ""):sub(1, 8)
		return {
			kind = "committed",
			actor = actor_from_login(author_name),
			date = tostring(author.date or date),
			label = sha ~= "" and string.format("%s %s", sha, msg) or msg,
		}
	elseif event == "base_ref_force_pushed" then
		return { kind = "force_pushed", actor = actor, date = date, label = "base branch force pushed" }
	elseif event == "labeled" or event == "unlabeled" then
		local label = type(item.label) == "table" and tostring(item.label.name or "") or ""
		if label == "" then
			return nil
		end
		local verb = event == "labeled" and "added label" or "removed label"
		return { kind = event, actor = actor, date = date, label = verb .. ": " .. label }
	elseif event == "assigned" or event == "unassigned" then
		local assignee = type(item.assignee) == "table" and tostring(item.assignee.login or "") or ""
		if assignee == "" then
			return nil
		end
		local verb = event == "assigned" and "assigned" or "unassigned"
		return { kind = event, actor = actor, date = date, label = verb .. " " .. assignee }
	elseif event == "review_requested" then
		local reviewer = type(item.requested_reviewer) == "table" and tostring(item.requested_reviewer.login or "")
			or ""
		return {
			kind = "review_requested",
			actor = actor,
			date = date,
			label = reviewer ~= "" and ("requested review from " .. reviewer) or "requested review",
		}
	elseif event == "ready_for_review" then
		return {
			kind = "ready_for_review",
			actor = actor,
			date = date,
			label = "marked as ready for review",
		}
	elseif event == "convert_to_draft" then
		return { kind = "convert_to_draft", actor = actor, date = date, label = "marked as draft" }
	end
	return nil
end

---@param raw table
---@return PullsComment
function M.to_activity_comment(raw)
	local user = type(raw.user) == "table" and raw.user or (type(raw.actor) == "table" and raw.actor or {})
	local reactions = nil
	if type(raw.reactions) == "table" then
		reactions = {
			["+1"] = tonumber(raw.reactions["+1"]) or 0,
			["-1"] = tonumber(raw.reactions["-1"]) or 0,
			laugh = tonumber(raw.reactions.laugh) or 0,
			hooray = tonumber(raw.reactions.hooray) or 0,
			confused = tonumber(raw.reactions.confused) or 0,
			heart = tonumber(raw.reactions.heart) or 0,
			rocket = tonumber(raw.reactions.rocket) or 0,
			eyes = tonumber(raw.reactions.eyes) or 0,
		}
	end
	return {
		id = raw.id,
		parent_id = nil,
		author = {
			name = tostring(user.login or ""),
			nickname = tostring(user.login or ""),
			id = tostring(user.id or ""),
		},
		content_raw = tostring(raw.body or ""),
		created_on = tostring(raw.created_at or raw.submitted_at or ""),
		deleted = false,
		inline = nil,
		url = nil,
		html_url = tostring(raw.html_url or ""),
		reactions = reactions,
	}
end

---@param raw table
---@param thread_state {resolved: boolean, outdated: boolean}|nil
---@return PullsComment
function M.to_comment(raw, thread_state)
	local user = raw.user or {}
	local line = json.nilify(raw.line)
	local original_line = json.nilify(raw.original_line)
	local path = json.nilify(raw.path)

	local inline, inline_hunk
	if path ~= nil then
		local side = raw.side == "LEFT" and "old" or "new"
		local anchor = line or original_line
		inline = {
			path = tostring(path),
			to = side == "new" and anchor or nil,
			from = side == "old" and anchor or nil,
		}
		inline_hunk = parse_diff_hunk(raw.diff_hunk)
	end

	---@type "RESOLVED"|"OUTDATED"|nil
	local state = nil
	if thread_state ~= nil then
		if thread_state.resolved then
			state = "RESOLVED"
		elseif thread_state.outdated then
			state = "OUTDATED"
		end
	end

	local reactions
	if type(raw.reactions) == "table" then
		reactions = {
			["+1"] = tonumber(raw.reactions["+1"]) or 0,
			["-1"] = tonumber(raw.reactions["-1"]) or 0,
			laugh = tonumber(raw.reactions.laugh) or 0,
			hooray = tonumber(raw.reactions.hooray) or 0,
			confused = tonumber(raw.reactions.confused) or 0,
			heart = tonumber(raw.reactions.heart) or 0,
			rocket = tonumber(raw.reactions.rocket) or 0,
			eyes = tonumber(raw.reactions.eyes) or 0,
		}
	end

	return {
		id = raw.id,
		parent_id = json.nilify(raw.in_reply_to_id),
		author = {
			name = tostring(user.login or ""),
			nickname = tostring(user.login or ""),
			id = tostring(user.id or ""),
		},
		content_raw = tostring(raw.body or ""),
		created_on = tostring(raw.created_at or ""),
		inline = inline,
		inline_hunk = inline_hunk,
		is_task = nil,
		state = state,
		url = nil,
		html_url = tostring(raw.html_url or ""),
		reactions = reactions,
	}
end

return M
