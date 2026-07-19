local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.issues.ui.main.helper")
local state = require("atlas.issues.state")

---@param status_id string|nil
---@return string, string
local function state_icon(status_id)
	if status_id == "closed" then
		return icons.pulls_status("successful"), "AtlasGHIssueClosed"
	end
	return icons.issues("issue"), "AtlasGHIssueOpen"
end

---@param status_id string|nil
---@return string
local function state_chip_hl(status_id)
	if status_id == "closed" then
		return "AtlasGHIssueClosedChip"
	end
	return "AtlasGHIssueOpenChip"
end

---@param issue Issue
---@return string
local function key_label(issue)
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local number = raw.number or 0
	local slug = tostring(raw.slug or "")
	return slug ~= "" and string.format("%s#%d", slug, number) or string.format("#%d", number)
end

---@param issue Issue
---@param is_child boolean
---@return table
function M.format_row(issue, is_child)
	local title = issue.summary or ""
	local label = key_label(issue)

	local is_pinned = issue.is_pinned == true
	local row_icon = is_pinned and icons.general("pin") or state_icon(issue.status_id)

	local name = is_child and ("  " .. row_icon .. "  " .. label .. "  " .. title)
		or (label .. "  " .. title)

	local assignee_name = type(issue.assignee) == "table" and issue.assignee.display_name or "Unassigned"
	local reporter_name = type(issue.reporter) == "table" and issue.reporter.display_name or "Unknown"

	return {
		icon = is_child and "" or row_icon,
		name = name,
		assignee = string.format("%s %s", icons.general("user"), utils.shorten_name(assignee_name, 20)),
		reporter = string.format("%s %s", icons.general("user"), utils.shorten_name(reporter_name, 20)),
		status = (function()
			local issue_key = tostring(issue.key or "")
			if issue_key ~= "" and state.is_issue_reloading(issue_key) then
				return string.format(" %s ", state.reload_spinner_frame or "⠋")
			end
			return string.format(" %s ", issue.status or "")
		end)(),
	}
end

---@param row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
function M.cell_hl(row, col, ctx)
	local issue = row._issue
	if type(issue) ~= "table" then
		return nil
	end

	if col.key == "icon" then
		local is_pinned = issue.is_pinned == true
		local s, icon_hl
		if is_pinned then
			s, icon_hl = icons.general("pin")
		else
			s, icon_hl = state_icon(issue.status_id)
		end
		if s == "" then
			return nil
		end
		local ss, ee = ctx.text:find(s, 1, true)
		if not ss or not ee then
			return nil
		end
		return { { start_col = ss - 1, end_col = ee, hl_group = icon_hl } }
	end

	if col.key == "name" then
		local spans = {}
		local is_child = (tonumber(row._tv2_depth) or 0) > 0
		if is_child then
			local s_icon, s_icon_hl = state_icon(issue.status_id)
			local is, ie = ctx.text:find(s_icon, 1, true)
			if is and ie then
				table.insert(spans, { start_col = is - 1, end_col = ie, hl_group = s_icon_hl })
			end
		end

		local label = key_label(issue)
		local s, e = ctx.text:find(label, 1, true)
		if s and e then
			table.insert(spans, { start_col = s - 1, end_col = e, hl_group = "AtlasGHIssueKey" })
			local title_start = e + 2
			if title_start <= #ctx.text then
				table.insert(spans, { start_col = title_start - 1, end_col = #ctx.text, hl_group = "Normal" })
			end
		end
		return #spans > 0 and spans or nil
	end

	if col.key == "status" then
		local issue_key = tostring(issue.key or "")
		local hl_group = issue_key ~= "" and state.is_issue_reloading(issue_key) and "AtlasTextMuted"
			or state_chip_hl(issue.status_id)
		return { { start_col = 0, end_col = #ctx.padded, hl_group = hl_group } }
	end

	if col.key == "assignee" then
		local name = type(issue.assignee) == "table" and issue.assignee.display_name or nil
		return { { start_col = 0, end_col = #ctx.padded, hl_group = helper.person_hl(name) } }
	end

	if col.key == "reporter" then
		local name = type(issue.reporter) == "table" and issue.reporter.display_name or nil
		return { { start_col = 0, end_col = #ctx.padded, hl_group = helper.person_hl(name) } }
	end

	return nil
end

---@param issue Issue
---@return string[], table[]
function M.issue_popup_content(issue)
	local raw = issue._raw or {}
	local summary = issue.summary or ""
	local key = issue.key or ""

	local lines = { string.format(" %s: %s", key, summary), "" }
	local highlights = {
		{ row = 0, col = 1, end_col = 1 + #key, hl_group = helper.issue_hl(key) },
		{ row = 1, col = 0, end_col = -1, hl_group = "AtlasTextMuted" },
	}
	if summary ~= "" then
		table.insert(highlights, {
			row = 0,
			col = 3 + #key,
			end_col = -1,
			hl_group = helper.issue_title_hl(summary),
		})
	end

	---@param label string
	---@param value string|nil
	---@param value_hl string|nil
	local function push(label, value, value_hl)
		if value == nil or value == "" then
			return
		end
		local row = #lines
		table.insert(lines, string.format(" %-10s %s", label .. ":", value))
		table.insert(highlights, { row = row, col = 1, end_col = 11, hl_group = "AtlasTextMuted" })
		if value_hl ~= nil then
			table.insert(highlights, { row = row, col = 12, end_col = -1, hl_group = value_hl })
		end
	end

	push("Status", issue.status, helper.status_hl(issue.status_id))

	local reporter_name = issue.reporter and issue.reporter.display_name or nil
	push("Author", reporter_name, helper.person_hl(reporter_name))

	local assignees = type(raw.assignees) == "table" and raw.assignees or {}
	if #assignees > 0 then
		local logins = {}
		for _, a in ipairs(assignees) do
			table.insert(logins, "@" .. tostring(a.login or ""))
		end
		push("Assignees", table.concat(logins, ", "), "AtlasTextMuted")
	end

	local labels = type(raw.labels) == "table" and raw.labels or {}
	if #labels > 0 then
		local names = {}
		for _, l in ipairs(labels) do
			table.insert(names, tostring(l.name or ""))
		end
		push("Labels", table.concat(names, ", "), "AtlasTextMuted")
	end

	local milestone = raw.milestone
	if type(milestone) == "table" and milestone.title then
		push("Milestone", tostring(milestone.title), "AtlasTextMuted")
	end

	push("Comments", tostring(tonumber(raw.comment_count) or 0), "AtlasTextMuted")
	push("Updated", utils.relative_time(raw.updated_at), "AtlasTextMuted")

	local content_width = 1
	for _, line in ipairs(lines) do
		content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
	end
	lines[2] = " " .. ("━"):rep(content_width)

	return lines, highlights
end

return M
