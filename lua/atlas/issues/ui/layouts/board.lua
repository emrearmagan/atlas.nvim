local M = {}

local config = require("atlas.config")
local ui_utils = require("atlas.ui.utils")
local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")

local MIN_COLUMN_WIDTH = 33
local COLUMN_GAP = 3
local MARGIN = 1

local function clean(value)
	return (tostring(value or ""):gsub("%c", " "))
end

---@param segments { text: string, hl_group?: string }[]
---@return string, { start_col: integer, end_col: integer, hl_group: string }[]
local function join(segments)
	local text, spans = "", {}
	for _, segment in ipairs(segments) do
		if segment.text ~= "" then
			if text ~= "" then
				text = text .. " "
			end
			if segment.hl_group then
				table.insert(spans, { start_col = #text, end_col = #text + #segment.text, hl_group = segment.hl_group })
			end
			text = text .. segment.text
		end
	end
	return text, spans
end

M.jira = {
	column_icon = function(status)
		local status_icons = config.options.issues.jira.project_config.status_icons
		return status_icons[status.name] or status_icons[status.category] or icons.get("fallback")
	end,
	card = function(issue, width)
		local star, star_hl = "", nil
		if issue.is_starred then
			star, star_hl = icons.get("star")
		end
		local priority, priority_hl = "", nil
		if issue.priority and issue.priority ~= "" then
			priority, priority_hl = icons.get(issue.priority, "priority")
		end
		local points = issue.story_points ~= nil
				and utils.truncate(clean(issue.story_points) .. " pts", math.floor(width / 3))
			or ""

		local title = { text = "" }
		local segments = {
			{ text = star, hl_group = star_hl },
			{ text = priority, hl_group = priority_hl },
			title,
			{ text = points, hl_group = "AtlasTextMuted" },
		}
		local without_title = join(segments)
		title.text = utils.truncate(clean(issue.title), width - ui_utils.text_width(without_title) - 1)

		local text, spans = join(segments)
		return { issue = issue, text = text, spans = spans }
	end,
}

local function status_columns(issues, statuses, provider)
	local columns, by_status = {}, {}

	local function column_for(status_id, name)
		status_id, name = clean(status_id), clean(name)
		local key = status_id ~= "" and ("id:" .. status_id) or ("name:" .. name)
		if by_status[key] == nil then
			by_status[key] = { name = name ~= "" and name or "Unknown", issues = {} }
			table.insert(columns, by_status[key])
		end
		return by_status[key]
	end

	for _, status in ipairs(statuses or {}) do
		local icon = provider.column_icon(status)
		column_for(status.id, status.name).name = clean(icon ~= "" and (icon .. " " .. status.name) or status.name)
	end
	for _, issue in ipairs(issues) do
		table.insert(column_for(issue.status_id, issue.status).issues, issue)
	end

	return vim.tbl_filter(function(column)
		return #column.issues > 0
	end, columns)
end

---@param count integer
---@param total_width integer
---@return integer[]
local function column_widths(count, total_width)
	local inner_width = total_width - 2 * MARGIN
	local fitting = math.floor((inner_width + COLUMN_GAP) / (MIN_COLUMN_WIDTH + COLUMN_GAP))
	local visible = math.max(1, math.min(count, fitting))
	local available = inner_width - (visible - 1) * COLUMN_GAP
	local width, extra = math.floor(available / visible), available % visible

	local widths = {}
	for index = 1, visible do
		widths[index] = math.max(1, width + (index <= extra and 1 or 0))
	end
	return widths
end

local function header(column)
	local count = string.format(" (%d)", #column.issues)
	local text = utils.truncate(column.name, column.width - #count) .. count
	return { text = text, spans = { { start_col = 0, end_col = #text, hl_group = "AtlasColumnHeader" } } }
end

local function render_row(columns, row, column_count)
	local parts, cells, spans = {}, {}, {}
	local col = MARGIN

	for index, column in ipairs(columns) do
		local content = column.rows[row] or { text = "", spans = {} }
		local padded = ui_utils.pad_right(content.text, column.width)

		parts[index] = padded
		cells[index] = { issue = content.issue, column = column.index, start_col = col, end_col = col + #padded }
		for _, span in ipairs(content.spans) do
			table.insert(spans, {
				line = row - 1,
				start_col = col + span.start_col,
				end_col = col + span.end_col,
				hl_group = span.hl_group,
			})
		end

		col = col + #padded + COLUMN_GAP
	end

	local line = string.rep(" ", MARGIN) .. table.concat(parts, string.rep(" ", COLUMN_GAP))
	return line, { kind = "board_row", cells = cells, column_count = column_count }, spans
end

---@param opts { width: integer, first_column?: integer, statuses?: JiraIssueStatus[], loading?: boolean, spinner?: string }
---@param issues Issue[]
---@param provider table
---@return string[], table<integer, table>, table[]
function M.render(opts, issues, provider)
	local loading = opts.loading and (" " .. (opts.spinner or "") .. " Loading...")
	if loading and #issues == 0 then
		return { loading }, {}, {}
	end

	local columns = status_columns(issues, opts.statuses, provider)
	if #columns == 0 then
		return { " No issues found." }, {}, {}
	end

	local widths = column_widths(#columns, opts.width)
	local first = math.max(1, math.min(opts.first_column or 1, #columns - #widths + 1))
	local visible, height = {}, 0
	for index, width in ipairs(widths) do
		local column = columns[first + index - 1]
		column.index = first + index - 1
		column.width = width
		column.rows = { header(column) }
		for _, issue in ipairs(column.issues) do
			table.insert(column.rows, provider.card(issue, width))
		end
		height = math.max(height, #column.rows)
		visible[index] = column
	end

	local lines, line_map, spans = {}, {}, {}
	for row = 1, height do
		local line, entry, row_spans = render_row(visible, row, #columns)
		lines[row] = line
		line_map[row] = entry
		vim.list_extend(spans, row_spans)
	end

	if loading then
		vim.list_extend(lines, { "", loading })
	end

	return lines, line_map, spans
end

return M
