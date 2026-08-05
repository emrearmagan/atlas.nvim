local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)
local COMMENT_ICON, COMMENT_ICON_HL = icons.general("comment")
local ISSUE_ICON = {
	open = { icon = icons.issues("issue"), hl = "AtlasPROpen" },
	closed = { icon = icons.pulls_status("successful"), hl = "AtlasTextPositive" },
}

---@param width integer
---@param lines string[]
---@param spans table[]
local function append_separator(width, lines, spans)
	local line = PADDING .. string.rep("─", math.max(8, width - (PADDING_X * 2)))
	table.insert(lines, line)
	table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #line, hl_group = "AtlasBorder" })
end

---@param state table
---@param width integer
---@param lines string[]
---@param spans table[]
local function render_filter_bar(state, width, lines, spans)
	local counts = state.counts
	local open_label = counts and string.format("Open (%d)", counts.open) or "Open"
	local closed_label = counts and string.format("Closed (%d)", counts.closed) or "Closed"
	local separator = "  "
	local line = PADDING .. open_label .. separator .. closed_label

	table.insert(lines, line)
	local line_index = #lines - 1
	local open_start = PADDING_X
	local open_end = open_start + #open_label
	local closed_start = open_end + #separator
	table.insert(spans, {
		line = line_index,
		start_col = open_start,
		end_col = open_end,
		hl_group = state.filter == "open" and "AtlasText" or "AtlasTextMuted",
	})
	table.insert(spans, {
		line = line_index,
		start_col = closed_start,
		end_col = closed_start + #closed_label,
		hl_group = state.filter == "closed" and "AtlasText" or "AtlasTextMuted",
	})
	append_separator(width, lines, spans)
end

---@param state table
---@param width integer
---@param repository_loading boolean
---@param issue_type_hl? fun(color: string): string
---@return string[], table[], table<integer, table>
function M.render(state, width, repository_loading, issue_type_hl)
	local lines = {}
	local spans = {}
	local line_map = {}

	if state.issues == nil then
		if repository_loading then
			utils.push(lines, spans, spinner.with_text("Loading repository..."), "AtlasTextMuted", PADDING_X)
		end
		return lines, spans, line_map
	end

	if state.issues == "loading" then
		render_filter_bar(state, width, lines, spans)
		utils.push(lines, spans, spinner.with_text("Loading issues..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	if type(state.issues) == "string" then
		render_filter_bar(state, width, lines, spans)
		utils.push(lines, spans, state.issues, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	local issues = state.issues
	render_filter_bar(state, width, lines, spans)
	if #issues == 0 then
		local label = state.filter == "open" and "No open issues." or "No closed issues."
		utils.push(lines, spans, label, "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	for i, issue in ipairs(issues) do
		local icon_entry = ISSUE_ICON[tostring(issue.state or ""):lower()] or ISSUE_ICON.open
		local title = tostring(issue.title or "")
		local number = tostring(issue.number or "")
		local author = tostring(issue.author or "")
		local comments = tonumber(issue.comments) or 0
		local date_text = utils.relative_time_text(issue.created_at)
		local icon_prefix = PADDING .. icon_entry.icon .. " "
		local icon_prefix_width = vim.api.nvim_strwidth(icon_prefix)
		local comment_text = comments > 0 and string.format("%s %d", COMMENT_ICON, comments) or ""
		local comment_width = comment_text ~= "" and vim.api.nvim_strwidth(comment_text) + 1 or 0
		local title_display = utils.truncate(title, math.max(1, width - icon_prefix_width - comment_width - 1))

		local title_line = icon_prefix .. title_display
		if comment_text ~= "" then
			local gap =
				math.max(1, width - icon_prefix_width - vim.api.nvim_strwidth(title_display) - comment_width - 1)
			title_line = title_line .. string.rep(" ", gap) .. comment_text .. " "
		end

		table.insert(lines, title_line)
		local title_line_index = #lines - 1
		line_map[#lines] = { kind = "issue", issue = issue, url = tostring(issue.url or "") }
		table.insert(spans, {
			line = title_line_index,
			start_col = PADDING_X,
			end_col = PADDING_X + #icon_entry.icon,
			hl_group = icon_entry.hl,
		})
		if comment_text ~= "" then
			local comment_start = #title_line - #comment_text - 1
			table.insert(spans, {
				line = title_line_index,
				start_col = comment_start,
				end_col = comment_start + #comment_text,
				hl_group = COMMENT_ICON_HL,
			})
		end

		local meta_line = PADDING .. "  "
		local meta_spans = {}
		local issue_type = issue.issue_type
		if issue_type_hl and issue_type and issue_type.name ~= "" then
			local chip = " " .. issue_type.name .. " "
			local chip_start = #meta_line
			meta_line = meta_line .. chip .. " "
			table.insert(meta_spans, {
				start_col = chip_start,
				end_col = chip_start + #chip,
				hl_group = issue_type_hl(issue_type.color),
			})
		end

		local meta_parts = { "#" .. number }
		if author ~= "" then
			table.insert(meta_parts, author .. " opened")
		end
		if date_text and date_text ~= "-" then
			table.insert(meta_parts, date_text)
		end
		local meta_start = #meta_line
		meta_line = meta_line .. table.concat(meta_parts, " · ")
		table.insert(meta_spans, { start_col = meta_start, end_col = #meta_line, hl_group = "AtlasTextMuted" })

		table.insert(lines, meta_line)
		local meta_line_index = #lines - 1
		for _, span in ipairs(meta_spans) do
			span.line = meta_line_index
			table.insert(spans, span)
		end

		if i < #issues then
			append_separator(width, lines, spans)
		end
	end

	return lines, spans, line_map
end

return M
