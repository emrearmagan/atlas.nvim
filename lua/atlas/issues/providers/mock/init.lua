local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.issues.ui.main.helper")

local M = {
	id = "mock",
	name = "Mock Issues",
	icon = icons.issues_provider("mock", "provider"),
	hl_group = "AtlasMockTheme",
}

local USERS = {
	me = { account_id = "mock-user-1", display_name = "Emre Armagan", email = "emre@example.test" },
	alex = { account_id = "mock-user-2", display_name = "Alex Morgan", email = "alex@example.test" },
	casey = { account_id = "mock-user-3", display_name = "Casey Lee", email = "casey@example.test" },
	robot = { account_id = "mock-bot-1", display_name = "Atlas Bot", email = "atlas-bot@example.test" },
}

local PROJECT = { id = "10000", key = "MOCK", name = "Mock Project", self = "mock://project/MOCK" }

local TYPES = {
	epic = { id = "1", name = "Epic", subtask = false },
	story = { id = "2", name = "Story", subtask = false },
	task = { id = "3", name = "Task", subtask = false },
	bug = { id = "4", name = "Bug", subtask = false },
	subtask = { id = "5", name = "Sub-task", subtask = true },
}

local STATUSES = {
	backlog = { name = "Backlog", id = "mock-backlog", category = "new", color = "blue-gray" },
	progress = { name = "In Progress", id = "mock-progress", category = "indeterminate", color = "yellow" },
	review = { name = "In Review", id = "mock-review", category = "indeterminate", color = "purple" },
	done = { name = "Done", id = "mock-done", category = "done", color = "green" },
}

local function iso(days_ago, hours_ago)
	local seconds = os.time() - ((tonumber(days_ago) or 0) * 86400) - ((tonumber(hours_ago) or 0) * 3600)
	return os.date("!%Y-%m-%dT%H:%M:%S.000+0000", seconds)
end

local function issue(key, summary, type_key, status_key, priority, assignee, reporter, points, due, parent)
	local status = STATUSES[status_key] or STATUSES.backlog
	return {
		key = key,
		summary = summary,
		project = PROJECT,
		status = status.name,
		status_id = status.id,
		status_category = status.category,
		status_color = status.color,
		type = TYPES[type_key] or TYPES.task,
		priority = priority,
		assignee = assignee,
		reporter = reporter,
		story_points = points,
		duedate = due,
		parent = parent,
	}
end

local ISSUES = {
	issue("MOCK-100", "Ship the repository panel polish", "epic", "progress", "High", USERS.me, USERS.alex, 13, "2026-05-08"),
	issue("MOCK-101", "Add branch deletion workflow", "story", "review", "Highest", USERS.me, USERS.alex, 5, "2026-04-30", { key = "MOCK-100", summary = "Ship the repository panel polish" }),
	issue("MOCK-102", "Mock Bitbucket refs for branch testing", "task", "done", "Medium", USERS.casey, USERS.me, 3, "2026-04-24", { key = "MOCK-100", summary = "Ship the repository panel polish" }),
	issue("MOCK-103", "Fix footer warning icon", "bug", "done", "Low", USERS.alex, USERS.me, 1, "2026-04-25"),
	issue("MOCK-104", "Create issue mock provider", "task", "progress", "Medium", USERS.me, USERS.casey, 8, "2026-05-02"),
	issue("MOCK-105", "Document provider-specific keymaps", "story", "backlog", "Low", nil, USERS.alex, 2, "2026-05-12"),
	issue("MOCK-106", "Subtask: cover comments flow", "subtask", "progress", "Medium", USERS.casey, USERS.me, nil, "2026-05-01", { key = "MOCK-104", summary = "Create issue mock provider" }),
}

local DESCRIPTIONS = {
	["MOCK-100"] = "# Repository panel polish\n\nTrack the work needed to make the repo panel feel complete.\n\n- Branches\n- Tags\n- Actions\n",
	["MOCK-101"] = "Add a destructive branch deletion action with confirmation and provider-backed API calls.",
	["MOCK-102"] = "Mock provider data for repository branch and tag lists.",
	["MOCK-103"] = "Footer warnings should render the warning icon consistently.",
	["MOCK-104"] = "Build a local issue provider so issue UI can be developed without Jira credentials.",
	["MOCK-105"] = "Keep README keymaps aligned with actual registered actions.",
	["MOCK-106"] = "Exercise add, reply, edit, and delete comment flows in mock issues.",
}

local COMMENTS = {
	["MOCK-101"] = {
		{ id = "c-101-1", author = USERS.alex, body = "Please make sure default branches cannot be deleted.", created = iso(1, 4), updated = iso(1, 4) },
		{ id = "c-101-2", author = USERS.me, body = "Handled locally before calling the provider.", parent_id = "c-101-1", created = iso(1, 3), updated = iso(1, 3) },
	},
	["MOCK-104"] = {
		{ id = "c-104-1", author = USERS.casey, body = "Mock provider should cover overview, comments, and history tabs.", created = iso(0, 8), updated = iso(0, 8) },
	},
}

local HISTORY = {
	["MOCK-101"] = {
		{
			id = "h-101-1",
			created = iso(2, 0),
			author = USERS.alex,
			items = { { field = "status", from = STATUSES.progress.id, from_string = "In Progress", to = STATUSES.review.id, to_string = "In Review" } },
		},
		{
			id = "h-101-2",
			created = iso(1, 5),
			author = USERS.me,
			items = { { field = "priority", from_string = "High", to_string = "Highest" } },
		},
	},
	["MOCK-104"] = {
		{
			id = "h-104-1",
			created = iso(0, 10),
			author = USERS.casey,
			items = { { field = "assignee", from_string = "Unassigned", to_string = USERS.me.display_name } },
		},
	},
}

local next_comment_id = 1000

local function handle_after(ms, fn)
	local cancelled = false
	vim.defer_fn(function()
		if not cancelled then
			fn()
		end
	end, ms)
	return { cancel = function() cancelled = true end }
end

local function copy(value)
	return vim.deepcopy(value)
end

local function find_issue(key)
	for _, item in ipairs(ISSUES) do
		if item.key == key then
			return item
		end
	end
	return nil
end

local function issue_matches_view(item, view)
	local name = tostring((view or {}).name or ""):lower()
	local jql = tostring((view or {}).jql or "")
	local keys = jql:match("key%s+in%s+%((.-)%)")
	if keys ~= nil then
		return keys:find('"' .. item.key .. '"', 1, true) ~= nil
	end
	if name:find("mine", 1, true) then
		return type(item.assignee) == "table" and item.assignee.account_id == USERS.me.account_id
	end
	if name:find("bugs", 1, true) then
		return type(item.type) == "table" and item.type.name == "Bug"
	end
	return true
end

function M.setup()
	require("atlas.ui.shared.highlights").setup()
	require("atlas.issues.providers.jira.highlights").setup()
	vim.api.nvim_set_hl(0, "AtlasMockTheme", { bg = "#334155", bold = true })
end

function M.on_refresh() end

---@param issue Issue
---@param is_child boolean
---@return table
function M.format_row(issue, is_child)
	local issue_type_name = type(issue.type) == "table" and issue.type.name or nil
	local type_icon = icons.issues_type(issue_type_name)
	local priority_icon = icons.issues_priority(issue.priority)
	local due = utils.format_date(issue.duedate)
	local meta = {}
	if priority_icon ~= "" then table.insert(meta, priority_icon) end
	if due ~= "" then table.insert(meta, icons.general("created") .. " " .. due) end

	local title = string.format("%s %s", issue.key, issue.summary or "")
	if is_child then
		title = string.format("%s %s", type_icon, title)
	end
	if #meta > 0 then
		title = title .. "  " .. table.concat(meta, "  ")
	end

	return {
		icon = is_child and "" or type_icon,
		name = is_child and ("  " .. title) or title,
		assignee = string.format("%s %s", icons.general("user"), (issue.assignee and issue.assignee.display_name) or "Unassigned"),
		reporter = string.format("%s %s", icons.general("user"), (issue.reporter and issue.reporter.display_name) or "Unknown"),
		status = string.format(" %s ", issue.status or ""),
	}
end

function M.cell_hl(row, col, ctx)
	local issue_item = row._issue
	if col.key == "icon" and type(issue_item) == "table" and type(issue_item.type) == "table" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = helper.issue_type_hl(issue_item.type.name) } }
	end
	if col.key == "name" and type(issue_item) == "table" then
		local spans = {}
		local key = tostring(issue_item.key or "")
		local s, e = ctx.text:find(key, 1, true)
		if s and e then
			table.insert(spans, { start_col = s - 1, end_col = e, hl_group = helper.issue_hl(key) })
		end
		local p_icon = icons.issues_priority(issue_item.priority)
		local ps, pe = ctx.text:find(p_icon, 1, true)
		if ps and pe then
			table.insert(spans, { start_col = ps - 1, end_col = pe, hl_group = helper.priority_hl(issue_item.priority) })
		end
		return #spans > 0 and spans or nil
	end
	if col.key == "status" and type(issue_item) == "table" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = helper.status_hl(issue_item.status_id) } }
	end
	if col.key == "assignee" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = helper.person_hl(type(issue_item) == "table" and issue_item.assignee or nil) } }
	end
	if col.key == "reporter" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = helper.person_hl(type(issue_item) == "table" and issue_item.reporter or nil) } }
	end
end

function M.fetch_user(on_done)
	return handle_after(80, function() on_done(copy(USERS.me), nil) end)
end

function M.fetch_issues(view, opts, on_done)
	opts = opts or {}
	return handle_after(180, function()
		local filtered = {}
		for _, item in ipairs(ISSUES) do
			if issue_matches_view(item, view) then
				table.insert(filtered, copy(item))
			end
		end
		local page_size = math.max(1, tonumber(opts.max_results) or #filtered)
		local start = math.max(1, tonumber(opts.next_page_token) or 1)
		local out = {}
		for i = start, math.min(#filtered, start + page_size - 1) do
			table.insert(out, filtered[i])
		end
		local next_index = start + #out
		local is_last = next_index > #filtered
		on_done(out, is_last and nil or tostring(next_index), is_last, nil)
	end)
end

function M.fetch_issue(issue_key, opts, on_done)
	if type(opts) == "function" and on_done == nil then on_done = opts end
	return handle_after(120, function()
		local found = find_issue(tostring(issue_key or ""))
		on_done(found and copy(found) or nil, found and nil or "Issue not found")
	end)
end

function M.fetch_description(issue_key, opts, on_done)
	if type(opts) == "function" and on_done == nil then on_done = opts end
	return handle_after(120, function()
		on_done(DESCRIPTIONS[tostring(issue_key or "")] or "No mock description.", nil)
	end)
end

function M.fetch_comments(issue_key, opts, on_done)
	if type(opts) == "function" and on_done == nil then on_done = opts end
	return handle_after(140, function()
		on_done(copy(COMMENTS[tostring(issue_key or "")] or {}), nil)
	end)
end

function M.fetch_history(issue_key, opts, on_done)
	if type(opts) == "function" and on_done == nil then on_done = opts end
	return handle_after(140, function()
		on_done(copy(HISTORY[tostring(issue_key or "")] or {}), nil)
	end)
end

function M.add_comment(issue_key, content, on_done)
	return handle_after(120, function()
		next_comment_id = next_comment_id + 1
		local key = tostring(issue_key or "")
		COMMENTS[key] = COMMENTS[key] or {}
		local comment = { id = "c-" .. next_comment_id, author = USERS.me, body = tostring(content or ""), created = iso(0, 0), updated = iso(0, 0) }
		table.insert(COMMENTS[key], comment)
		on_done(copy(comment), nil)
	end)
end

function M.reply_comment(issue_key, parent_id, content, on_done)
	return handle_after(120, function()
		next_comment_id = next_comment_id + 1
		local key = tostring(issue_key or "")
		COMMENTS[key] = COMMENTS[key] or {}
		local comment = { id = "c-" .. next_comment_id, parent_id = parent_id, author = USERS.me, body = tostring(content or ""), created = iso(0, 0), updated = iso(0, 0) }
		table.insert(COMMENTS[key], comment)
		on_done(copy(comment), nil)
	end)
end

function M.edit_comment(issue_key, comment_id, content, on_done)
	return handle_after(120, function()
		for _, comment in ipairs(COMMENTS[tostring(issue_key or "")] or {}) do
			if tostring(comment.id) == tostring(comment_id) then
				comment.body = tostring(content or "")
				comment.updated = iso(0, 0)
				on_done(copy(comment), nil)
				return
			end
		end
		on_done(nil, "Comment not found")
	end)
end

function M.delete_comment(issue_key, comment_id, on_done)
	return handle_after(120, function()
		local comments = COMMENTS[tostring(issue_key or "")] or {}
		for i, comment in ipairs(comments) do
			if tostring(comment.id) == tostring(comment_id) then
				table.remove(comments, i)
				on_done(true, nil)
				return
			end
		end
		on_done(false, "Comment not found")
	end)
end

function M.search(on_done)
	if on_done then
		on_done({ changed_issue = false, message = "Mock search is not interactive" }, nil)
	end
end

function M.views()
	return {
		{ name = "All Mock Issues", key = "1", jql = "mock all" },
		{ name = "Mine", key = "2", jql = "assignee = currentUser()" },
		{ name = "Bugs", key = "3", jql = "type = Bug" },
	}
end

M.panel = {
	tabs = function()
		return {
			{ key = "overview", label = "Overview", icon = icons.general("overview"), mod = require("atlas.issues.ui.panel.issue.tabs.overview") },
			{ key = "comments", label = "Comments", icon = icons.general("comment"), mod = require("atlas.issues.ui.panel.issue.tabs.comments") },
			{ key = "activity", label = "History", icon = icons.pulls("activity"), mod = require("atlas.issues.ui.panel.issue.tabs.activity") },
		}
	end,
	chips = function(item)
		local parent_key = item.parent and item.parent.key or nil
		return {
			{ label = string.format("%s %s", icons.pulls("branch"), parent_key or "-"), hl = parent_key and "AtlasChipActive" or "AtlasTextMuted" },
			{ label = string.format("%s %s", icons.issues_provider("mock", "provider"), type(item.story_points) == "number" and tostring(item.story_points) or "-"), hl = "AtlasTextMuted" },
			{ label = string.format("%s %s", icons.general("created"), utils.format_date(item.duedate) ~= "" and utils.format_date(item.duedate) or "-"), hl = "AtlasTextMuted" },
		}
	end,
	convert_description = function(raw)
		return type(raw) == "string" and raw or vim.inspect(raw)
	end,
	format_history_item = function(item)
		local field = item.field or "field"
		local from = item.from_string or item.from or ""
		local to = item.to_string or item.to or ""
		if from ~= "" or to ~= "" then
			return { label = "updated " .. field, content = string.format("%s -> %s", from, to) }
		end
		return { label = "updated " .. field, content = nil }
	end,
	history_item_hl = function(item, row)
		local s, e = row:find(" -> ", 1, true)
		if not s then return nil end
		if item.field == "assignee" then
			return {
				{ start_col = 0, end_col = s - 1, hl_group = helper.person_hl(item.from_string or item.from) },
				{ start_col = e, end_col = #row, hl_group = helper.person_hl(item.to_string or item.to) },
			}
		end
		if item.field == "priority" then
			return {
				{ start_col = 0, end_col = s - 1, hl_group = helper.priority_hl(item.from_string or item.from) },
				{ start_col = e, end_col = #row, hl_group = helper.priority_hl(item.to_string or item.to) },
			}
		end
		return nil
	end,
	resolve_comment_body = function(body)
		return body
	end,
}

return M
