local M = {}

local state = require("atlas.issues.state")
local helper = require("atlas.issues.ui.main.helper")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@param name string|nil
---@return string, string
local function type_icon(name)
	return icons.issues_type(name)
end

---@param name string|nil
---@return string, string
local function priority_icon(name)
	return icons.issues_priority(name)
end

---@param issue Issue
---@param is_child boolean
---@return table
function M.format_row(issue, is_child)
	local issue_type_name = type(issue.type) == "table" and issue.type.name or nil
	local t_icon = type_icon(issue_type_name)
	local icon = is_child and "" or t_icon
	local title = is_child and (t_icon .. " " .. issue.key .. " " .. issue.summary)
		or (issue.key .. " " .. issue.summary)
	local due_display = utils.format_date(issue.duedate)
	local p_icon = priority_icon(issue.priority)
	local points_due = ""
	if p_icon ~= "" then
		points_due = p_icon
	end
	if due_display ~= "" then
		local due_text = icons.general("created") .. " " .. due_display
		if points_due ~= "" then
			points_due = points_due .. "  " .. due_text
		else
			points_due = due_text
		end
	end
	local name = points_due ~= "" and (title .. "  " .. points_due) or title
	if is_child then
		name = "  " .. name
	end

	return {
		icon = icon,
		name = name,
		assignee = string.format(
			"%s %s",
			icons.general("user"),
			utils.shorten_name((type(issue.assignee) == "table" and issue.assignee.display_name) or "Unassigned", 20)
		),
		reporter = string.format("%s %s", icons.general("user"), utils.shorten_name((type(issue.reporter) == "table" and issue.reporter.display_name) or "Unknown", 20)),
		status = (function()
			local issue_key = tostring(issue.key or "")
			local is_reloading = issue_key ~= "" and (tonumber((state.reloading_issue_keys or {})[issue_key]) or 0) > 0
			if is_reloading then
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

	if col.key == "name" then
		local spans_for_cell = {}
		local is_child = (tonumber(row._tv2_depth) or 0) > 0
		local issue_type_name = type(issue) == "table" and type(issue.type) == "table" and issue.type.name or nil

		if is_child and type(issue) == "table" then
			local issue_icon, issue_icon_hl = type_icon(issue_type_name)
			local is, ie = ctx.text:find(issue_icon, 1, true)
			if is and ie then
				table.insert(spans_for_cell, {
					start_col = is - 1,
					end_col = ie,
					hl_group = issue_icon_hl,
				})
			end
		end

		if type(issue) == "table" and type(issue.key) == "string" and issue.key ~= "" then
			local s, e = ctx.text:find(issue.key, 1, true)
			if s and e then
				local title_start = e + 2
				if title_start <= #ctx.text then
					table.insert(spans_for_cell, {
						start_col = title_start - 1,
						end_col = #ctx.text,
						hl_group = helper.issue_title_hl(is_child and "" or issue.summary),
					})
				end

				table.insert(spans_for_cell, {
					start_col = s - 1,
					end_col = e,
					hl_group = helper.issue_hl(is_child and "" or issue.key),
				})
			end
		end

		if type(issue) == "table" and type(issue.priority) == "string" and issue.priority ~= "" then
			local p_icon, p_icon_hl = priority_icon(issue.priority)
			local ps, pe = ctx.text:find(p_icon, 1, true)
			if ps and pe then
				table.insert(spans_for_cell, {
					start_col = ps - 1,
					end_col = pe,
					hl_group = p_icon_hl,
				})
			end
		end

		return #spans_for_cell > 0 and spans_for_cell or nil
	end

	if col.key == "status" then
		local issue_key = type(issue) == "table" and tostring(issue.key or "") or ""
		local is_reloading = issue_key ~= "" and (tonumber((state.reloading_issue_keys or {})[issue_key]) or 0) > 0
		local hl_group = is_reloading and "AtlasTextMuted"
			or helper.status_hl(type(issue) == "table" and issue.status_id or nil)
		return {
			{ start_col = 0, end_col = #ctx.padded, hl_group = hl_group },
		}
	end

	if col.key == "icon" then
		local issue_type_name = type(issue) == "table" and type(issue.type) == "table" and issue.type.name or nil
		local t_icon, t_icon_hl = type_icon(issue_type_name)
		if t_icon == "" then
			return nil
		end
		local s, e = ctx.text:find(t_icon, 1, true)
		if not s or not e then
			return nil
		end
		return {
			{ start_col = s - 1, end_col = e, hl_group = t_icon_hl },
		}
	end

	if col.key == "assignee" then
		local assignee_name = nil
		if type(issue) == "table" and type(issue.assignee) == "table" then
			assignee_name = issue.assignee.display_name
		end
		return {
			{ start_col = 0, end_col = #ctx.padded, hl_group = helper.person_hl(assignee_name) },
		}
	end

	if col.key == "reporter" then
		return {
			{
				start_col = 0,
				end_col = #ctx.padded,
				hl_group = helper.person_hl(
					type(issue) == "table" and type(issue.reporter) == "table" and issue.reporter.display_name or nil
				),
			},
		}
	end

	return nil
end

return M
