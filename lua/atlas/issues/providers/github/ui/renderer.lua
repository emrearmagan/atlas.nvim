local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.issues.ui.main.helper")
local state = require("atlas.issues.state")

---@param status_id string|nil
---@return string
local function state_icon(status_id)
	if status_id == "closed" then
		return icons.pulls_status("successful")
	end
	return icons.issues("issue")
end

---@param status_id string|nil
---@return string
local function state_hl(status_id)
	if status_id == "closed" then
		return "AtlasGHIssueClosed"
	end
	return "AtlasGHIssueOpen"
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
---@param is_child boolean
---@return table
function M.format_row(issue, is_child)
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local number = raw.number or 0
	local title = issue.summary or ""
	local slug = tostring(raw.slug or "")

	local key_label = slug ~= "" and string.format("%s#%d", slug, number) or string.format("#%d", number)
	local is_pinned = issue.is_pinned == true
	local row_icon = is_pinned and icons.general("pin") or state_icon(issue.status_id)

	local name = is_child and ("  " .. row_icon .. "  " .. key_label .. "  " .. title)
		or (key_label .. "  " .. title)

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
		local s = is_pinned and icons.general("pin") or state_icon(issue.status_id)
		if s == "" then
			return nil
		end
		local ss, ee = ctx.text:find(s, 1, true)
		if not ss or not ee then
			return nil
		end
		local hl = is_pinned and "AtlasTextWarning" or state_hl(issue.status_id)
		return { { start_col = ss - 1, end_col = ee, hl_group = hl } }
	end

	if col.key == "name" then
		local spans = {}
		local is_child = (tonumber(row._tv2_depth) or 0) > 0
		if is_child then
			local s_icon = state_icon(issue.status_id)
			local is, ie = ctx.text:find(s_icon, 1, true)
			if is and ie then
				table.insert(spans, { start_col = is - 1, end_col = ie, hl_group = state_hl(issue.status_id) })
			end
		end

		local raw = type(issue._raw) == "table" and issue._raw or {}
		local number = raw.number or 0
		local slug = tostring(raw.slug or "")
		local key_label = slug ~= "" and string.format("%s#%d", slug, number) or string.format("#%d", number)
		local s, e = ctx.text:find(key_label, 1, true)
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

return M
