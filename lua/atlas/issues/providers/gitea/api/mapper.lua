local M = {}

local json = require("atlas.core.json")

---@param raw_user table|nil
---@return IssueUser|nil
function M.to_user(raw_user)
	raw_user = json.nilify(raw_user)
	if type(raw_user) ~= "table" then
		return nil
	end
	local login = json.safe_str(raw_user.login) or ""
	if login == "" then
		return nil
	end
	local full_name = json.safe_str(raw_user.full_name) or ""
	local display_name = full_name ~= "" and full_name or login
	return {
		account_id = login,
		display_name = display_name,
	}
end

---@param state string|nil
---@return string, string
local function normalize_state(state)
	local s = tostring(state or ""):lower()
	if s == "closed" then
		return "Closed", "closed"
	end
	return "Open", "open"
end

---@param raw_repo table|nil
---@param fallback_slug string|nil
---@return string slug
local function extract_repo(raw_repo, fallback_slug)
	local slug = ""
	raw_repo = json.nilify(raw_repo)
	if type(raw_repo) == "table" then
		slug = json.safe_str(raw_repo.full_name) or ""
		if slug == "" then
			local owner = json.safe_str(raw_repo.owner) or ""
			local name = json.safe_str(raw_repo.name) or ""
			if owner ~= "" and name ~= "" then
				slug = owner .. "/" .. name
			end
		end
	end
	if slug == "" then
		slug = tostring(fallback_slug or "")
	end
	return slug
end

---@param raw table
---@param fallback_slug string|nil
---@return Issue|nil
function M.to_issue(raw, fallback_slug)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local number = tonumber(raw.number)
	if number == nil then
		return nil
	end

	local slug = extract_repo(raw.repository, fallback_slug)
	local url = json.safe_str(raw.html_url) or ""
	if slug == "" then
		local extracted = url:match("/([^/]+/[^/]+)/issues/")
		if extracted then
			slug = extracted
		end
	end

	local key = slug ~= "" and string.format("%s#%d", slug, number) or string.format("#%d", number)
	local title = json.safe_str(raw.title) or ""
	local status_name, status_id = normalize_state(raw.state)

	local author = M.to_user(raw.user)
	local assignee = M.to_user(raw.assignee)
	if assignee == nil then
		local assignees = json.safe_table(json.nilify(raw.assignees))
		for _, a in ipairs(assignees) do
			local u = M.to_user(a)
			if u then
				assignee = u
				break
			end
		end
	end

	local labels = json.safe_table(json.nilify(raw.labels))
	local milestone = json.nilify(raw.milestone)
	local body = json.safe_str(raw.body) or ""
	local created_at = json.safe_str(raw.created_at) or ""
	local updated_at = json.safe_str(raw.updated_at) or ""
	local closed_at = json.safe_str(raw.closed_at)

	local comment_count = tonumber(raw.comments) or 0

	local pin_order = tonumber(raw.pin_order) or 0

	---@type Issue
	local issue = {
		key = key,
		summary = title,
		project = nil,
		status = status_name,
		status_id = status_id,
		status_category = nil,
		status_color = nil,
		type = nil,
		priority = nil,
		assignee = assignee,
		reporter = author,
		story_points = nil,
		duedate = nil,
		parent = nil,
		url = url ~= "" and url or nil,
		is_pinned = pin_order > 0,
		is_subscribed = nil,
		_raw = {
			number = number,
			slug = slug,
			body = body,
			created_at = created_at,
			updated_at = updated_at,
			closed_at = closed_at,
			labels = labels,
			assignees = json.safe_table(json.nilify(raw.assignees)),
			milestone = milestone,
			comment_count = comment_count,
			html_url = url,
		},
	}
	return issue
end

---@param raw_list table[]|nil
---@param fallback_slug string|nil
---@return Issue[]
function M.to_issues_list(raw_list, fallback_slug)
	local out = {}
	for _, raw in ipairs(raw_list or {}) do
		local issue = M.to_issue(raw, fallback_slug)
		if issue ~= nil then
			table.insert(out, issue)
		end
	end
	return out
end

---@param key string
---@return string slug, integer|nil number
function M.parse_key(key)
	local k = tostring(key or "")
	local slug, num = k:match("^(.-)#(%d+)$")
	if slug and num then
		return slug, tonumber(num)
	end
	return "", nil
end

---@param raw table
---@return IssueComment|nil
function M.to_comment(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" or json.nilify(raw.id) == nil then
		return nil
	end
	local author = M.to_user(raw.user)
	return {
		id = tostring(raw.id),
		self = nil,
		url = json.safe_str(raw.html_url) or "",
		author = author,
		body = json.safe_str(raw.body) or "",
		_body = nil,
		created = json.safe_str(raw.created_at) or "",
		updated = json.safe_str(raw.updated_at),
		parent_id = nil,
		children = nil,
		reactions = nil,
	}
end

---@param raw_list table[]|nil
---@return IssueComment[]
function M.to_comments_list(raw_list)
	local out = {}
	for _, raw in ipairs(raw_list or {}) do
		local c = M.to_comment(raw)
		if c ~= nil then
			table.insert(out, c)
		end
	end
	return out
end

---@param hex string|nil
---@return string|nil
local function label_hl_group(hex)
	if type(hex) ~= "string" or hex == "" then
		return nil
	end
	local clean = hex:lower():gsub("[^0-9a-f]", "")
	if #clean ~= 6 then
		return nil
	end
	local name = "AtlasGiteaIssueLabel_" .. clean
	pcall(vim.api.nvim_set_hl, 0, name, { fg = "#" .. clean, bold = true })
	return name
end

-- Map Gitea timeline event type → internal kind
local TYPE_MAP = {
	close = "closed",
	reopen = "reopened",
	label = "labeled",
	remove_label = "unlabeled",
	milestone = "milestoned",
	demilestone = "demilestoned",
	assignees = "assigned",
	rename = "renamed",
	comment = "comment",
}

---@param raw table
---@return IssueActivityEntry|nil
function M.to_timeline_entry(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local raw_type = json.safe_str(raw.type) or ""
	if raw_type == "" then
		return nil
	end

	-- comments are handled separately
	if raw_type == "comment" then
		return nil
	end

	local event = TYPE_MAP[raw_type] or raw_type

	local actor = M.to_user(raw.user)
	local date = json.safe_str(raw.created_at) or ""

	---@type IssueActivityEntry
	local entry = { kind = event, actor = actor, date = date }

	if event == "labeled" or event == "unlabeled" then
		local label = json.nilify(raw.label)
		local name = type(label) == "table" and (json.safe_str(label.name) or "") or ""
		local color = type(label) == "table" and (json.safe_str(label.color) or "") or ""
		entry.label = event == "labeled" and "added label" or "removed label"
		if name ~= "" then
			entry.body = name
			local hl = label_hl_group(color)
			if hl then
				entry.body_hl = function(row, _)
					return { { start_col = 0, end_col = #row, hl_group = hl } }
				end
			end
		end
	elseif event == "assigned" then
		entry.label = "assigned"
	elseif event == "milestoned" or event == "demilestoned" then
		local milestone = json.nilify(raw.milestone)
		local title = type(milestone) == "table" and (json.safe_str(milestone.title) or "") or ""
		entry.label = event == "milestoned" and "added milestone" or "removed milestone"
		entry.body = title ~= "" and title or nil
	elseif event == "renamed" then
		local rename = json.nilify(raw.rename)
		local from = type(rename) == "table" and (json.safe_str(rename.from) or "") or ""
		local to = type(rename) == "table" and (json.safe_str(rename.to) or "") or ""
		entry.label = "renamed"
		if from ~= "" or to ~= "" then
			entry.body = from .. " → " .. to
			entry.body_hl = function(row, _)
				local s, e = row:find(" → ", 1, true)
				if not s then
					return nil
				end
				return {
					{ start_col = 0, end_col = s - 1, hl_group = "AtlasTextWarning" },
					{ start_col = e, end_col = #row, hl_group = "AtlasTextPositive" },
				}
			end
		end
	elseif event == "closed" then
		entry.label = "closed"
	elseif event == "reopened" then
		entry.label = "reopened"
	else
		entry.label = event
	end

	return entry
end

---@param raw table
---@return IssueComment|nil
function M.to_timeline_comment(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local raw_type = json.safe_str(raw.type) or ""
	if raw_type ~= "comment" then
		return nil
	end
	return M.to_comment(raw)
end

return M
