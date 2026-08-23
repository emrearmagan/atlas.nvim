local M = {}

local helper = require("atlas.issues.ui.presentation")
local icons = require("atlas.ui.shared.icons")
local state = require("atlas.issues.state")
local utils = require("atlas.ui.shared.utils")

local function columns()
	return {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue" },
		{
			key = "assignee",
			name = string.format("%s Assignee", icons.general("user")),
			max_width = 22,
			can_grow = false,
		},
		{
			key = "reporter",
			name = string.format("%s Reporter", icons.general("user")),
			max_width = 22,
			can_grow = false,
		},
		{ key = "status", name = " Status", can_grow = false },
	}
end

---@param issue Issue
---@return string
local function status_value(issue)
	local issue_key = tostring(issue.key or "")
	if issue_key ~= "" and state.is_issue_reloading(issue_key) then
		return string.format(" %s ", state.reload_spinner_frame or "⠋")
	end
	return string.format(" %s ", issue.status or "")
end

---@param user IssueUser|nil
---@param fallback string
---@return string
local function person_value(user, fallback)
	local name = user and user.display_name or fallback
	return string.format("%s %s", icons.general("user"), utils.shorten_name(name, 20))
end

---@param issue Issue
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
local function person_highlight(issue, col, ctx)
	if col.key == "assignee" then
		local name = issue.assignee and issue.assignee.display_name or nil
		return { { start_col = 0, end_col = #ctx.padded, hl_group = helper.person_hl(name) } }
	end
	if col.key == "reporter" then
		local name = issue.reporter and issue.reporter.display_name or nil
		return { { start_col = 0, end_col = #ctx.padded, hl_group = helper.person_hl(name) } }
	end
end

local function github()
	local function state_icon(status_id)
		if status_id == "closed" then
			return icons.pulls_status("successful"), "AtlasGHIssueClosed"
		end
		return icons.issues("issue"), "AtlasGHIssueOpen"
	end

	local function state_chip_hl(status_id)
		return status_id == "closed" and "AtlasGHIssueClosedChip" or "AtlasGHIssueOpenChip"
	end

	local function key_label(issue)
		local key = tostring(issue.key or "")
		local number = tonumber((issue._raw or {}).number) or tonumber(key:match("#(%d+)$"))
		return number and string.format("#%d", number) or key
	end

	local function github_columns(layout)
		local result = {
			{ key = "icon", name = "", can_grow = false, align = "center", header_hl = "AtlasColumnHeader" },
			{ key = "name", name = "Issue", min_width = 42, header_hl = "AtlasColumnHeader" },
			{
				key = "comments",
				name = icons.general("comment"),
				min_width = 2,
				can_grow = false,
				header_hl = "AtlasColumnHeader",
			},
			{
				key = "assignee",
				name = string.format("%s Assignee", icons.general("user")),
				max_width = 22,
				can_grow = false,
				header_hl = "AtlasColumnHeader",
			},
			{
				key = "reporter",
				name = string.format("%s Reporter", icons.general("user")),
				max_width = 22,
				can_grow = false,
				header_hl = "AtlasColumnHeader",
			},
		}
		if layout == "compact" then
			table.insert(result, {
				key = "created",
				name = icons.general("created"),
				can_grow = false,
				header_hl = "AtlasColumnHeader",
			})
			table.insert(result, {
				key = "updated",
				name = icons.general("updated"),
				can_grow = false,
				header_hl = "AtlasColumnHeader",
			})
		end
		table.insert(result, {
			key = "status",
			name = " Status",
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		})
		return result
	end

	local function values(issue, is_child, layout)
		local label = key_label(issue)
		local is_pinned = issue.is_pinned == true
		local row_icon = is_pinned and icons.general("pin") or state_icon(issue.status_id)
		local name = is_child and ("  " .. row_icon .. "  " .. label .. " " .. (issue.title or ""))
			or (label .. " " .. (issue.title or ""))

		local result = {
			icon = is_child and "" or row_icon,
			name = name,
			_key_label = label,
			comments = tostring(tonumber(issue.comment_count) or 0),
			assignee = person_value(issue.assignee, "Unassigned"),
			reporter = person_value(issue.reporter, "Unknown"),
			status = status_value(issue),
		}
		if layout == "compact" then
			result.created = utils.relative_time(issue.created_at)
			result.updated = utils.relative_time(issue.updated_at)
			local repository = tostring((issue._raw or {}).slug or "")
			result._meta = repository ~= "" and repository or (tostring(issue.key or ""):match("^(.-)#%d+$") or "")
		end
		return result
	end

	local function highlights(table_row, col, ctx)
		local issue = table_row._issue
		if issue == nil then
			return nil
		end

		if col.key == "icon" then
			local icon, icon_hl
			if issue.is_pinned == true then
				icon, icon_hl = icons.general("pin")
			else
				icon, icon_hl = state_icon(issue.status_id)
			end
			local start_col, end_col = ctx.text:find(icon, 1, true)
			if start_col then
				return { { start_col = start_col - 1, end_col = end_col, hl_group = icon_hl } }
			end
		end

		if col.key == "name" then
			local spans = {}
			if (tonumber(table_row._tv2_depth) or 0) > 0 then
				local icon, icon_hl = state_icon(issue.status_id)
				local start_col, end_col = ctx.text:find(icon, 1, true)
				if start_col then
					table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = icon_hl })
				end
			end

			local label = table_row._key_label or key_label(issue)
			local start_col, end_col = ctx.text:find(label, 1, true)
			if start_col then
				table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = "AtlasTextMuted" })
				local title_start = end_col + 2
				if title_start <= #ctx.text then
					table.insert(spans, {
						start_col = title_start - 1,
						end_col = #ctx.text,
						hl_group = "Normal",
					})
				end
			end
			return #spans > 0 and spans or nil
		end

		if col.key == "comments" or col.key == "created" or col.key == "updated" then
			return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
		end
		if col.key == "status" then
			local issue_key = tostring(issue.key or "")
			local hl = issue_key ~= "" and state.is_issue_reloading(issue_key) and "AtlasTextMuted"
				or state_chip_hl(issue.status_id)
			return { { start_col = 0, end_col = #ctx.padded, hl_group = hl } }
		end
		return person_highlight(issue, col, ctx)
	end

	return {
		columns = github_columns,
		values = values,
		highlights = highlights,
	}
end

local function gitlab()
	local function state_icon(status_id)
		if status_id == "closed" then
			return icons.pulls_status("successful"), "AtlasGLIssueClosed"
		end
		return icons.issues("issue"), "AtlasGLIssueOpen"
	end

	local function state_chip_hl(status_id)
		return status_id == "closed" and "AtlasGLIssueClosedChip" or "AtlasGLIssueOpenChip"
	end

	local function key_label(issue)
		local key = tostring(issue.key or "")
		local number = tonumber((issue._raw or {}).iid) or tonumber(key:match("#(%d+)$"))
		return number and string.format("#%d", number) or key
	end

	local function values(issue, is_child)
		local label = key_label(issue)
		local row_icon = state_icon(issue.status_id)
		return {
			icon = is_child and "" or row_icon,
			name = is_child and ("  " .. row_icon .. "  " .. label .. " " .. (issue.title or ""))
				or (label .. " " .. (issue.title or "")),
			_key_label = label,
			assignee = person_value(issue.assignee, "Unassigned"),
			reporter = person_value(issue.reporter, "Unknown"),
			status = status_value(issue),
		}
	end

	local function highlights(table_row, col, ctx)
		local issue = table_row._issue
		if issue == nil then
			return nil
		end

		if col.key == "icon" then
			local icon, icon_hl = state_icon(issue.status_id)
			local start_col, end_col = ctx.text:find(icon, 1, true)
			if start_col then
				return { { start_col = start_col - 1, end_col = end_col, hl_group = icon_hl } }
			end
		end

		if col.key == "name" then
			local spans = {}
			if (tonumber(table_row._tv2_depth) or 0) > 0 then
				local icon, icon_hl = state_icon(issue.status_id)
				local start_col, end_col = ctx.text:find(icon, 1, true)
				if start_col then
					table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = icon_hl })
				end
			end

			local label = table_row._key_label or key_label(issue)
			local start_col, end_col = ctx.text:find(label, 1, true)
			if start_col then
				table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = "AtlasTextMuted" })
				local title_start = end_col + 2
				if title_start <= #ctx.text then
					table.insert(spans, {
						start_col = title_start - 1,
						end_col = #ctx.text,
						hl_group = "Normal",
					})
				end
			end
			return #spans > 0 and spans or nil
		end

		if col.key == "status" then
			local issue_key = tostring(issue.key or "")
			local hl = issue_key ~= "" and state.is_issue_reloading(issue_key) and "AtlasTextMuted"
				or state_chip_hl(issue.status_id)
			return { { start_col = 0, end_col = #ctx.padded, hl_group = hl } }
		end
		return person_highlight(issue, col, ctx)
	end

	return { columns = columns, values = values, highlights = highlights }
end

local function jira()
	local function values(issue, is_child)
		local type_icon = icons.issues_type(issue.type and issue.type.name or nil)
		local title = is_child and (type_icon .. " " .. issue.key .. " " .. issue.title)
			or (issue.key .. " " .. issue.title)
		local priority_icon = icons.issues_priority(issue.priority)
		local due = utils.format_date(issue.duedate)
		local suffix = priority_icon
		if due ~= "" then
			local due_text = icons.general("created") .. " " .. due
			suffix = suffix ~= "" and (suffix .. "  " .. due_text) or due_text
		end
		local name = suffix ~= "" and (title .. "  " .. suffix) or title
		return {
			icon = is_child and "" or type_icon,
			name = is_child and ("  " .. name) or name,
			assignee = person_value(issue.assignee, "Unassigned"),
			reporter = person_value(issue.reporter, "Unknown"),
			status = status_value(issue),
		}
	end

	local function highlights(table_row, col, ctx)
		local issue = table_row._issue
		if issue == nil then
			return nil
		end

		local issue_type = issue.type and issue.type.name or nil
		if col.key == "name" then
			local spans = {}
			if (tonumber(table_row._tv2_depth) or 0) > 0 then
				local icon, icon_hl = icons.issues_type(issue_type)
				local start_col, end_col = ctx.text:find(icon, 1, true)
				if start_col then
					table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = icon_hl })
				end
			end

			if issue.key ~= "" then
				local start_col, end_col = ctx.text:find(issue.key, 1, true)
				if start_col then
					local title_start = end_col + 2
					if title_start <= #ctx.text then
						table.insert(spans, {
							start_col = title_start - 1,
							end_col = #ctx.text,
							hl_group = helper.issue_title_hl(
								(tonumber(table_row._tv2_depth) or 0) > 0 and "" or issue.title
							),
						})
					end
					table.insert(spans, {
						start_col = start_col - 1,
						end_col = end_col,
						hl_group = helper.issue_hl((tonumber(table_row._tv2_depth) or 0) > 0 and "" or issue.key),
					})
				end
			end

			if issue.priority and issue.priority ~= "" then
				local icon, icon_hl = icons.issues_priority(issue.priority)
				local start_col, end_col = ctx.text:find(icon, 1, true)
				if start_col then
					table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = icon_hl })
				end
			end
			return #spans > 0 and spans or nil
		end

		if col.key == "status" then
			local issue_key = tostring(issue.key or "")
			local hl = issue_key ~= "" and state.is_issue_reloading(issue_key) and "AtlasTextMuted"
				or helper.status_hl(issue.status_id)
			return { { start_col = 0, end_col = #ctx.padded, hl_group = hl } }
		end
		if col.key == "icon" then
			local icon, icon_hl = icons.issues_type(issue_type)
			local start_col, end_col = ctx.text:find(icon, 1, true)
			if start_col then
				return { { start_col = start_col - 1, end_col = end_col, hl_group = icon_hl } }
			end
		end
		return person_highlight(issue, col, ctx)
	end

	return { columns = columns, values = values, highlights = highlights }
end

local function default()
	return {
		columns = columns,
		values = function(issue)
			return {
				icon = "",
				name = (issue.key or "") .. " " .. (issue.title or ""),
				assignee = (issue.assignee and issue.assignee.display_name) or "Unassigned",
				reporter = (issue.reporter and issue.reporter.display_name) or "Unknown",
				status = string.format(" %s ", issue.status or ""),
			}
		end,
	}
end

local displays = {
	github = github(),
	gitlab = gitlab(),
	jira = jira(),
}

---@param provider_id string|nil
---@return table
function M.get(provider_id)
	return displays[provider_id] or default()
end

return M
