local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.issues.ui.main.helper")
local state = require("atlas.issues.state")

---@param status_id string|nil
---@return string, string
local function state_icon(status_id)
	if status_id == "closed" then
		return icons.pulls_status("successful"), "AtlasGiteaIssueClosed"
	end
	return icons.issues("issue"), "AtlasGiteaIssueOpen"
end

---@param status_id string|nil
---@return string
local function state_chip_hl(status_id)
	return status_id == "closed" and "AtlasGiteaIssueClosedChip" or "AtlasGiteaIssueOpenChip"
end

---@param issue Issue
---@return string
local function key_label(issue)
	local raw = issue._raw
	local number = raw.number
	local path = raw.project_path
	return string.format("%s#%d", path, number)
end

---@param issue Issue
---@param is_child boolean
---@return table
function M.format_row(issue, is_child)
	local icon = issue.is_pinned and icons.general("pin") or state_icon(issue.status_id)
	local key = key_label(issue)
	local title = issue.summary
	local assignee = issue.assignee and issue.assignee.display_name or "Unassigned"
	local reporter = issue.reporter and issue.reporter.display_name or "Unknown"
	return {
		icon = is_child and "" or icon,
		name = is_child and ("  " .. icon .. "  " .. key .. "  " .. title) or (key .. "  " .. title),
		assignee = string.format("%s %s", icons.general("user"), utils.shorten_name(assignee, 20)),
		reporter = string.format("%s %s", icons.general("user"), utils.shorten_name(reporter, 20)),
		status = (function()
			local issue_key = issue.key
			if issue_key ~= "" and state.is_issue_reloading(issue_key) then
				return string.format(" %s ", state.reload_spinner_frame or "⠋")
			end
			return string.format(" %s ", issue.status)
		end)(),
	}
end

---@param row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
function M.cell_hl(row, col, ctx)
	local issue = row._issue
	if not issue then
		return nil
	end

	if col.key == "icon" then
		local icon, icon_hl = state_icon(issue.status_id)
		if issue.is_pinned then
			icon, icon_hl = icons.general("pin"), "AtlasTextWarning"
		end
		local first, last = ctx.text:find(icon, 1, true)
		return first and { { start_col = first - 1, end_col = last, hl_group = icon_hl } } or nil
	end

	if col.key == "name" then
		local spans = {}
		if (row._tv2_depth or 0) > 0 then
			local icon, icon_hl = state_icon(issue.status_id)
			if issue.is_pinned then
				icon, icon_hl = icons.general("pin"), "AtlasTextWarning"
			end
			local first, last = ctx.text:find(icon, 1, true)
			if first then
				table.insert(spans, { start_col = first - 1, end_col = last, hl_group = icon_hl })
			end
		end
		local first, last = ctx.text:find(key_label(issue), 1, true)
		if first then
			table.insert(spans, { start_col = first - 1, end_col = last, hl_group = "AtlasGiteaIssueKey" })
		end
		return #spans > 0 and spans or nil
	end

	if col.key == "status" then
		local issue_key = issue.key
		local hl = issue_key ~= "" and state.is_issue_reloading(issue_key) and "AtlasTextMuted"
			or state_chip_hl(issue.status_id)
		return { { start_col = 0, end_col = #ctx.padded, hl_group = hl } }
	end

	if col.key == "assignee" then
		return {
			{
				start_col = 0,
				end_col = #ctx.padded,
				hl_group = helper.person_hl(issue.assignee and issue.assignee.display_name or nil),
			},
		}
	end

	if col.key == "reporter" then
		return {
			{
				start_col = 0,
				end_col = #ctx.padded,
				hl_group = helper.person_hl(issue.reporter and issue.reporter.display_name or nil),
			},
		}
	end
end

return M
