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

local function cell_content(column, row)
	if row == 0 then
		local count = string.format(" (%d)", #column.cards)
		local text = utils.truncate(column.name, COLUMN_WIDTH - #count) .. count

		return text, { { start_col = 0, end_col = #text, hl_group = "AtlasColumnHeader" } }
	end

	local card = column.cards[row]
	if card then
		return card.text, card.spans, card.issue
	end

	if row == 1 and #column.cards == 0 then
		return "No issues", { { start_col = 0, end_col = #"No issues", hl_group = "AtlasTextMuted" } }
	end

	return "", {}
end

local function render_row(columns, row)
	local parts, cells, spans = {}, {}, {}
	local byte_col = MARGIN

	for index, column in ipairs(columns) do
		local text, highlights, issue = cell_content(column, row)
		local padded = ui_utils.pad_right(text, COLUMN_WIDTH)

		parts[index] = padded
		cells[index] = {
			kind = issue and "issue" or "issue_column",
			key = issue and issue.key,
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

		byte_col = byte_col + #padded + COLUMN_GAP
	end

	local line = string.rep(" ", MARGIN) .. table.concat(parts, string.rep(" ", COLUMN_GAP))

	return line, { kind = "board_row", cells = cells }, spans
end

local function jira_card(issue)
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
	local key = utils.truncate(clean(issue.key), key_width, true)
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

	return { issue = issue, text = text, spans = spans }
end

---@param opts { statuses?: JiraIssueStatus[], loading?: boolean, spinner?: string }
---@param issues JiraIssue[]
---@return string[], table<integer, table>, table[]
function M.jira(opts, issues)
	local loading = opts.loading and (" " .. (opts.spinner or "") .. " Loading...")
	if loading and #issues == 0 then
		return { loading }, {}, {}
	end

	local columns, by_status = {}, {}

	local function column_for(status_id, name)
		status_id, name = clean(status_id), clean(name)
		local key = status_id ~= "" and ("id:" .. status_id) or ("name:" .. name)
		local column = by_status[key]

		if column == nil then
			column = { name = name ~= "" and name or "Unknown", cards = {} }
			by_status[key] = column
			table.insert(columns, column)
		end

		return column
	end

	for _, status in ipairs(opts.statuses or {}) do
		local column = column_for(status.id, status.name)
		local icon = icons.issues_status(status.category, status.name)

		column.name = clean(icon ~= "" and (icon .. " " .. status.name) or status.name)
	end

	for _, issue in ipairs(issues) do
		local column = column_for(issue.status_id, issue.status)
		table.insert(column.cards, jira_card(issue))
	end

	if #columns == 0 then
		return { " No issues found." }, {}, {}
	end

	local height = 1
	for _, column in ipairs(columns) do
		height = math.max(height, #column.cards)
	end

	local lines, line_map, spans = {}, {}, {}

	for row = 0, height do
		local line, entry, highlights = render_row(columns, row)

		lines[#lines + 1] = line
		line_map[#lines] = entry
		vim.list_extend(spans, highlights)
	end

	if loading then
		table.insert(lines, "")
		table.insert(lines, loading)
	end

	return lines, line_map, spans
end

return M
