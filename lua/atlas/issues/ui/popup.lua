local M = {}

local state = require("atlas.issues.state")
local helper = require("atlas.issues.ui.dashboard.helper")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local function add(rows, label, value, hl_group)
	if value == nil or value == "" then
		return
	end
	rows[#rows + 1] = { label, tostring(value), hl_group or "AtlasTextMuted" }
end

local function generic_rows(issue)
	local rows = {}
	local issue_type = issue.type and issue.type.name or nil
	local _, issue_type_hl = icons.issues_type(issue_type)
	local _, priority_hl = icons.issues_priority(issue.priority)
	local assignee = issue.assignee and issue.assignee.display_name or nil
	local reporter = issue.reporter and issue.reporter.display_name or nil

	add(rows, "Type", issue_type, issue_type_hl)
	add(rows, "Status", issue.status, helper.status_hl(issue.status_id))
	add(rows, "Priority", issue.priority, priority_hl)
	add(rows, "Assignee", assignee or "Unassigned", helper.person_hl(assignee))
	add(rows, "Reporter", reporter, helper.person_hl(reporter))
	add(rows, "Due", issue.duedate)
	add(rows, "Points", issue.story_points)

	local parent = issue.parent
	local parent_key = parent and tostring(parent.key or "") or ""
	if parent_key ~= "" then
		local parent_title = tostring(parent.title or "")
		local value = parent_title ~= "" and (parent_key .. " — " .. parent_title) or parent_key
		add(rows, "Parent", value, helper.issue_hl(parent_key))
	end
	if issue.comment_count ~= nil then
		add(rows, "Comments", tostring(issue.comment_count))
	end
	if type(issue.created_at) == "string" and issue.created_at ~= "" then
		add(rows, "Created", utils.relative_time(issue.created_at))
	end
	if type(issue.updated_at) == "string" and issue.updated_at ~= "" then
		add(rows, "Updated", utils.relative_time(issue.updated_at))
	end

	return rows
end

local function github_rows(_issue)
	return {}
end

local function gitlab_rows(issue)
	local rows = {}
	local raw = issue._raw or {}
	local kind = tostring(raw.issue_type or ""):gsub("_", " ")
	if kind ~= "" then
		kind = kind:sub(1, 1):upper() .. kind:sub(2)
		add(rows, "Kind", kind)
	end

	if raw.confidential == true then
		add(rows, "Visibility", "Confidential", "AtlasTextWarning")
	end
	return rows
end

local function jira_rows(issue)
	local rows = {}
	local project = issue.project
	if project then
		add(rows, "Project", project.name ~= "" and project.name or project.key)
	end
	if issue.is_subscribed ~= nil then
		add(rows, "Watching", issue.is_subscribed and "Yes" or "No")
	end
	return rows
end

local provider_rows = {
	github = github_rows,
	gitlab = gitlab_rows,
	jira = jira_rows,
}

local function render(issue, rows)
	local key = tostring(issue.key or "")
	local title = tostring(issue.title or "")
	local lines = { string.format(" %s: %s", key, title), "" }
	local highlights = {
		{ line = 0, start_col = 1, end_col = 1 + #key, hl_group = helper.issue_hl(key) },
	}
	if title ~= "" then
		highlights[#highlights + 1] = {
			line = 0,
			start_col = 3 + #key,
			end_col = #lines[1],
			hl_group = helper.issue_title_hl(title),
		}
	end

	local label_width = 10
	for _, row in ipairs(rows) do
		label_width = math.max(label_width, #row[1] + 1)
	end
	for _, row in ipairs(rows) do
		local line = #lines
		lines[#lines + 1] = string.format(" %-" .. label_width .. "s %s", row[1] .. ":", row[2])
		highlights[#highlights + 1] = {
			line = line,
			start_col = 1,
			end_col = label_width + 1,
			hl_group = "AtlasTextMuted",
		}
		highlights[#highlights + 1] = {
			line = line,
			start_col = label_width + 2,
			end_col = #lines[line + 1],
			hl_group = row[3],
		}
	end

	local width = 1
	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end
	lines[2] = " " .. ("━"):rep(math.max(1, width - 1))
	highlights[#highlights + 1] = { line = 1, start_col = 0, end_col = #lines[2], hl_group = "AtlasTextMuted" }
	return lines, highlights
end

---@param issue Issue
---@return string[], AtlasUIHighlight[]
function M.content(issue)
	local rows = generic_rows(issue)
	local provider = state.provider
	local extend = provider and provider_rows[provider.id] or nil
	if extend then
		vim.list_extend(rows, extend(issue))
	end
	return render(issue, rows)
end

return M
