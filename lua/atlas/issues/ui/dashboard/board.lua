local M = {}

local ui_utils = require("atlas.ui.utils")
local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local presentation = require("atlas.issues.ui.presentation")

local COLUMN_WIDTH = 38
local COLUMN_GAP = 3
local MARGIN = 1

local function clean(value)
	return (tostring(value or ""):gsub("%c", " "))
end

local function group_issues(issues, provider_id, statuses)
	local columns, by_status = {}, {}

	local function add_column(id, name)
		local column = { name = name, issues = {} }
		by_status[id] = column
		columns[#columns + 1] = column
		return column
	end

	if statuses == nil and (provider_id == "github" or provider_id == "gitlab") then
		add_column("id:open", "Open")
		add_column("id:closed", "Closed")
	end

	local function status_column(status_id, name)
		name = clean(name)
		status_id = clean(status_id)
		local id = status_id ~= "" and ("id:" .. status_id) or ("name:" .. name)
		if name == "" then
			name = "Unknown"
		end
		return by_status[id] or add_column(id, name)
	end

	for _, status in ipairs(statuses or {}) do
		status_column(status.id, status.name)
	end
	for _, issue in ipairs(issues) do
		local column
		if provider_id == "github" and statuses then
			---@cast issue GitHubIssue
			column = by_status["id:" .. (issue.project_status_id or "no_status")] or by_status["id:no_status"]
		else
			column = status_column(issue.status_id, issue.status)
		end
		column.issues[#column.issues + 1] = issue
	end
	return columns
end

local function issue_text(issue)
	local key = clean(issue.key)
	local prefix, star_hl = "", nil
	if issue.is_starred then
		prefix, star_hl = icons.general("star")
		prefix = prefix .. " "
	end
	local priority, priority_hl = icons.issues_priority(issue.priority)
	local priority_text = priority ~= "" and (priority .. " ") or ""
	local points = issue.story_points ~= nil and (clean(issue.story_points) .. " pts") or ""
	local metadata = points ~= "" and (" " .. points) or ""
	local key_width = math.min(16, COLUMN_WIDTH - ui_utils.text_width(prefix .. priority_text .. metadata) - 2)
	key = utils.truncate(key:match("#%d+$") or key, key_width, true)
	local suffix = (key ~= "" and (" " .. key) or "") .. metadata
	local title_width = COLUMN_WIDTH - ui_utils.text_width(prefix .. priority_text .. suffix)
	local title = utils.truncate(clean(issue.title), title_width)
	local text = prefix .. priority_text .. title .. suffix
	local spans = {}
	if key ~= "" then
		spans[#spans + 1] = {
			start_col = #text - #metadata - #key,
			end_col = #text - #metadata,
			hl_group = presentation.issue_hl(issue.key),
		}
	end
	if priority ~= "" then
		spans[#spans + 1] = {
			start_col = #prefix,
			end_col = #prefix + #priority,
			hl_group = priority_hl,
		}
	end
	if points ~= "" then
		spans[#spans + 1] = { start_col = #text - #points, end_col = #text, hl_group = "AtlasTextMuted" }
	end
	if star_hl then
		spans[#spans + 1] = { start_col = 0, end_col = #prefix - 1, hl_group = star_hl }
	end
	return text, spans
end

---@param opts { issues: Issue[], provider_id: string, statuses?: IssueStatus[] }
---@return string[] lines
---@return table<integer, table> line_map
---@return table[] spans
function M.render(opts)
	local columns = group_issues(opts.issues or {}, opts.provider_id, opts.statuses)
	if #columns == 0 then
		return { " No issues found." }, {}, {}
	end

	local height = 1
	for _, column in ipairs(columns) do
		height = math.max(height, #column.issues)
	end
	local lines, line_map, spans = {}, {}, {}
	for row = 0, height do
		local parts = { string.rep(" ", MARGIN) }
		local cells = {}
		local byte_col = MARGIN
		for index, column in ipairs(columns) do
			local issue = row > 0 and column.issues[row] or nil
			local text, highlights = "", {}
			if row == 0 then
				local count = string.format(" (%d)", #column.issues)
				text = utils.truncate(column.name, COLUMN_WIDTH - #count) .. count
				highlights = { { start_col = 0, end_col = #text, hl_group = "AtlasColumnHeader" } }
			elseif issue then
				text, highlights = issue_text(issue)
			elseif row == 1 and #column.issues == 0 then
				text = "No issues"
				highlights = { { start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" } }
			end
			local padded = ui_utils.pad_right(text, COLUMN_WIDTH)
			parts[#parts + 1] = padded
			cells[#cells + 1] = {
				kind = issue and "issue" or "issue_column",
				key = issue and issue.key or nil,
				_issue = issue,
				column = index,
				start_col = byte_col,
				end_col = byte_col + #padded,
				virt_col = MARGIN + (index - 1) * (COLUMN_WIDTH + COLUMN_GAP),
				width = COLUMN_WIDTH,
			}
			for _, span in ipairs(highlights) do
				spans[#spans + 1] = {
					line = row,
					start_col = byte_col + span.start_col,
					end_col = byte_col + span.end_col,
					hl_group = span.hl_group,
				}
			end
			if index < #columns then
				parts[#parts + 1] = string.rep(" ", COLUMN_GAP)
			end
			byte_col = byte_col + #padded + COLUMN_GAP
		end
		lines[#lines + 1] = table.concat(parts)
		line_map[#lines] = { kind = "board_row", cells = cells }
	end
	return lines, line_map, spans
end

return M
