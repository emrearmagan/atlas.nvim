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

---@param issue Issue
---@return string[], table[]
function M.issue_popup_content(issue)
	local raw = issue._raw or {}
	local fields = type(raw.fields) == "table" and raw.fields or {}
	local summary = issue.summary or ""
	local key = issue.key or ""
	local parent_key = issue.parent and issue.parent.key or nil
	local parent_summary = issue.parent and issue.parent.summary or nil

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

	local issue_type_name = issue.type and issue.type.name or nil
	local _, issue_type_hl = icons.issues_type(issue_type_name)
	local _, priority_hl = icons.issues_priority(issue.priority)
	push("Type", issue_type_name, issue_type_hl)
	push("Status", issue.status, helper.status_hl(issue.status_id))
	push("Priority", issue.priority, priority_hl)

	local assignee_name = issue.assignee and issue.assignee.display_name or nil
	push("Assignee", assignee_name or "Unassigned", helper.person_hl(assignee_name))

	local reporter_name = issue.reporter and issue.reporter.display_name or nil
	if reporter_name then
		push("Reporter", reporter_name, helper.person_hl(reporter_name))
	end

	push("Due", issue.duedate, "AtlasTextMuted")

	if issue.story_points ~= nil then
		push("Points", tostring(issue.story_points), "AtlasTextMuted")
	end

	---@param list any
	---@param field string|nil
	---@return string[]
	local function names(list, field)
		local out = {}
		if type(list) ~= "table" then
			return out
		end
		for _, item in ipairs(list) do
			if field == nil then
				if type(item) == "string" and item ~= "" then
					table.insert(out, item)
				end
			elseif type(item) == "table" then
				local v = item[field]
				if type(v) == "string" and v ~= "" then
					table.insert(out, v)
				end
			end
		end
		return out
	end

	local labels = names(fields.labels)
	if #labels > 0 then
		push("Labels", table.concat(labels, ", "), "AtlasTextMuted")
	end

	local components = names(fields.components, "name")
	if #components > 0 then
		push("Components", table.concat(components, ", "), "AtlasTextMuted")
	end

	local fix_versions = names(fields.fixVersions, "name")
	if #fix_versions > 0 then
		push("Fix In", table.concat(fix_versions, ", "), "AtlasTextMuted")
	end

	local resolution = type(fields.resolution) == "table" and fields.resolution.name or nil
	if type(resolution) == "string" then
		push("Resolved", resolution, "AtlasTextMuted")
	end

	push("Updated", utils.relative_time(fields.updated), "AtlasTextMuted")

	if parent_key and parent_key ~= "" then
		push("Parent", parent_key, helper.issue_hl(parent_key))
		if parent_summary and parent_summary ~= "" then
			local row = #lines
			table.insert(lines, string.format("            %s", parent_summary))
			table.insert(highlights, { row = row, col = 12, end_col = -1, hl_group = "Comment" })
		end
	end

	local content_width = 1
	for _, line in ipairs(lines) do
		content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
	end
	lines[2] = " " .. ("━"):rep(content_width)

	return lines, highlights
end

return M
