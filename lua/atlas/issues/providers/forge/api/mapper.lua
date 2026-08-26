local json = require("atlas.core.json")

local M = {}

---@class ForgeIssueMapper
---@field to_user fun(raw: table|nil): IssueUser|nil
---@field to_issue fun(raw: table, scoped_slug: string|nil): GiteaIssue|ForgejoIssue|nil
---@field to_issue_details fun(raw: table, scoped_slug: string|nil): GiteaIssueDetails|ForgejoIssueDetails|nil
---@field to_comment fun(raw: table): IssueComment
---@field to_timeline_entry fun(raw: table): IssueActivityEntry|nil
---@field parse_key fun(key: string): string, integer|nil

---@param provider_id ForgeProviderId
---@return ForgeIssueMapper
function M.new(provider_id)
	---@type ForgeIssueMapper
	local mapper = {}

	---@param raw table|nil
	---@return IssueUser|nil
	local function user(raw)
		raw = json.nilify(raw)
		if raw == nil then
			return nil
		end
		local login = raw.login
		local name = raw.full_name
		return {
			id = raw.id,
			account_id = login,
			display_name = name ~= "" and name or login,
		}
	end

	---@param values table[]
	---@return (GiteaIssueLabel|ForgejoIssueLabel)[]
	local function labels(values)
		local result = {}
		for _, raw in ipairs(values) do
			table.insert(result, {
				id = raw.id,
				name = raw.name,
				color = raw.color,
			})
		end
		return result
	end

	---@param values table[]
	---@return IssueUser[]
	local function assignees(values)
		local result = {}
		for _, raw in ipairs(values) do
			local assignee = user(raw)
			if assignee then
				table.insert(result, assignee)
			end
		end
		return result
	end

	---@param raw table|nil
	---@return GiteaIssueMilestone|ForgejoIssueMilestone|nil
	local function milestone(raw)
		raw = json.nilify(raw)
		if raw == nil then
			return nil
		end
		local open_issues = tonumber(raw.open_issues) or 0
		local closed_issues = tonumber(raw.closed_issues) or 0
		local total = open_issues + closed_issues
		return {
			id = raw.id,
			title = raw.title,
			progress_percentage = total > 0 and (closed_issues / total) * 100 or nil,
			open_issues = open_issues,
			closed_issues = closed_issues,
		}
	end

	local timeline_events = {
		reopen = { "reopened", "reopened" },
		close = { "closed", "closed" },
		issue_ref = { "referenced", "referenced" },
		commit_ref = { "referenced", "referenced from a commit" },
		comment_ref = { "referenced", "referenced from a comment" },
		pull_ref = { "referenced", "referenced from a pull request" },
		lock = { "locked", "locked conversation" },
		unlock = { "unlocked", "unlocked conversation" },
		pin = { "pinned", "pinned" },
		unpin = { "unpinned", "unpinned" },
	}

	---@param value string|nil
	---@return string|nil
	local function nonempty(value)
		local result = json.nilify(value)
		return result ~= "" and result or nil
	end

	---@param raw table|nil
	---@param field string
	---@return string|nil
	local function object_name(raw, field)
		raw = json.nilify(raw)
		return raw and nonempty(raw[field]) or nil
	end

	---@param before string|nil
	---@param after string|nil
	---@return string|nil
	local function change(before, after)
		if before and after then
			return before .. " → " .. after
		end
		return after or before
	end

	mapper.to_user = user

	---@param raw table
	---@param scoped_slug string|nil Repository slug supplied by repository-scoped endpoints.
	---@return GiteaIssue|ForgejoIssue|nil
	function mapper.to_issue(raw, scoped_slug)
		if json.nilify(raw.pull_request) ~= nil then
			return nil
		end

		local number = raw.number
		local url = raw.html_url
		local slug = scoped_slug or (raw.repository and raw.repository.full_name or "")
		local state = raw.state
		local raw_assignees = json.nilify(raw.assignees) or {}
		local reporter = user(raw.user)
		local original_author = nonempty(raw.original_author)
		if not reporter and original_author then
			reporter = {
				id = raw.original_author_id,
				account_id = original_author,
				display_name = original_author,
			}
		end
		local due_date = nonempty(raw.due_date)
		local display_due_date = due_date and (due_date:match("^%d%d%d%d%-%d%d%-%d%d") or due_date) or nil

		return {
			key = string.format("%s#%d", slug, number),
			title = raw.title,
			project = nil,
			status = state == "closed" and "Closed" or "Open",
			status_id = state,
			type = nil,
			priority = nil,
			assignee = user(raw_assignees[1]),
			reporter = reporter,
			story_points = nil,
			duedate = display_due_date,
			parent = nil,
			url = url,
			created_at = json.nilify(raw.created_at),
			updated_at = json.nilify(raw.updated_at),
			closed_at = json.nilify(raw.closed_at),
			comment_count = raw.comments,
			is_subscribed = json.nilify(raw.subscribed),
			number = number,
			repo_full_name = slug,
			is_pinned = (tonumber(raw.pin_order) or 0) > 0,
			is_locked = json.nilify(raw.is_locked) == true,
			content_version = provider_id == "gitea" and json.nilify(raw.content_version) or nil,
			due_date = due_date,
		}
	end

	---@param raw table
	---@param _scoped_slug string|nil Repository slug supplied by repository-scoped endpoints.
	---@return GiteaIssueDetails|ForgejoIssueDetails|nil
	function mapper.to_issue_details(raw, _scoped_slug)
		if json.nilify(raw.pull_request) ~= nil then
			return nil
		end

		return {
			description = json.nilify(raw.body) or "",
			assignees = assignees(json.nilify(raw.assignees) or {}),
			labels = labels(json.nilify(raw.labels) or {}),
			milestone = milestone(json.nilify(raw.milestone)),
		}
	end

	---@param raw table
	---@return IssueComment
	function mapper.to_comment(raw)
		return {
			id = tostring(raw.id),
			self = nil,
			url = raw.html_url,
			author = user(raw.user),
			body = raw.body,
			created = raw.created_at,
			updated = json.nilify(raw.updated_at),
			parent_id = nil,
			children = nil,
			reactions = nil,
		}
	end

	---@param raw table
	---@return IssueActivityEntry|nil
	function mapper.to_timeline_entry(raw)
		local raw_type = raw.type
		if raw_type == "comment" then
			return nil
		end

		local event = timeline_events[raw_type]
		---@type IssueActivityEntry
		local entry = {
			kind = event and event[1] or raw_type,
			actor = user(raw.user),
			date = nonempty(raw.created_at),
			label = event and event[2] or raw_type:gsub("_", " "),
			body = nonempty(raw.body),
		}

		if raw_type == "label" then
			local added = raw.body == "1"
			entry.kind = added and "labeled" or "unlabeled"
			entry.label = added and "added label" or "removed label"
			entry.body = object_name(raw.label, "name")
		elseif raw_type == "milestone" then
			local before = object_name(raw.old_milestone, "title")
			local after = object_name(raw.milestone, "title")
			entry.kind = after and "milestoned" or "demilestoned"
			entry.label = after and (before and "changed milestone" or "added milestone") or "removed milestone"
			entry.body = change(before, after)
		elseif raw_type == "assignees" then
			local assignee = user(raw.assignee)
			local team = object_name(raw.assignee_team, "name")
			local removed = raw.removed_assignee == true
			entry.kind = removed and "unassigned" or "assigned"
			entry.label = removed and "unassigned" or "assigned"
			entry.body = assignee and assignee.display_name or team
		elseif raw_type == "change_title" then
			entry.kind = "renamed"
			entry.label = "renamed"
			entry.body = change(nonempty(raw.old_title), nonempty(raw.new_title))
		elseif raw_type == "change_issue_ref" or raw_type == "change_target_branch" then
			entry.label = raw_type == "change_issue_ref" and "changed issue reference" or "changed target branch"
			entry.body = change(nonempty(raw.old_ref), nonempty(raw.new_ref))
		elseif entry.kind == "referenced" then
			entry.body = object_name(raw.ref_issue, "title") or nonempty(raw.ref_commit_sha)
		elseif raw_type == "add_dependency" or raw_type == "remove_dependency" then
			entry.body = object_name(raw.dependent_issue, "title") or entry.body
		end

		return entry
	end

	---@param key string
	---@return string, integer|nil
	function mapper.parse_key(key)
		local slug, number = key:match("^([^/]+/[^/]+)#(%d+)$")
		return slug or "", tonumber(number)
	end

	return mapper
end

return M
