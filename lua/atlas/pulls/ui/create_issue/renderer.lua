local M = {}

local table_tree = require("atlas.ui.components.table_tree")
local pulls_helper = require("atlas.pulls.ui.main.helper")
local icons = require("atlas.ui.shared.icons")

local NS = vim.api.nvim_create_namespace("atlas.pulls.create_issue.meta")

---@param assignees CreateIssueAssignee[]
---@return string
local function format_assignees(assignees)
	if type(assignees) ~= "table" or #assignees == 0 then
		return icons.general("user") .. " Unassigned"
	end
	local parts = {}
	for _, a in ipairs(assignees) do
		table.insert(parts, "@" .. tostring(a.login or ""))
	end
	return icons.general("user") .. " " .. table.concat(parts, ", ")
end

---@param hex string|nil
---@return string
local function label_hl(hex)
	if type(hex) ~= "string" or not hex:match("^%x%x%x%x%x%x$") then
		return "AtlasTextMuted"
	end

	local r = tonumber(hex:sub(1, 2), 16) or 0
	local g = tonumber(hex:sub(3, 4), 16) or 0
	local b = tonumber(hex:sub(5, 6), 16) or 0
	local luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255
	local fg = luminance > 0.6 and "#111827" or "#f9fafb"

	local name = string.format("AtlasGHLabel_%s", hex:lower())
	vim.api.nvim_set_hl(0, name, { fg = fg, bg = "#" .. hex, bold = true })
	return name
end

---@param milestone CreateIssueMilestone|nil
---@return string
local function format_milestone(milestone)
	if type(milestone) ~= "table" then
		return "None"
	end
	return tostring(milestone.title or string.format("#%s", tostring(milestone.number or "")))
end

---@param state CreateIssueState
function M.render_meta(state)
	local buf = state.layout.meta_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local repo = tostring(state.fields.repo_slug or "")
	local assignees_text = format_assignees(state.fields.assignees)
	local milestone_text = format_milestone(state.fields.milestone)

	local rows = {
		{
			k1 = "Repo:",
			v1 = repo,
			v1_hl = pulls_helper.repo_hl(repo),
			k2 = "Milestone:",
			v2 = milestone_text,
			v2_hl = state.fields.milestone and "AtlasText" or "AtlasTextMuted",
		},
		{
			k1 = "Assignees:",
			v1 = assignees_text,
			v1_hl = (#state.fields.assignees > 0) and "AtlasText" or "AtlasTextMuted",
			k2 = "",
			v2 = "",
			v2_hl = "AtlasTextMuted",
		},
	}

	local lines, _, spans = table_tree.render({
		columns = {
			{ key = "k1", name = "", can_grow = false },
			{ key = "v1", name = "", can_grow = true },
			{ key = "k2", name = "", can_grow = false },
			{ key = "v2", name = "", can_grow = true, grow_last = true },
		},
		rows = rows,
		width = state.content_width,
		margin = 0,
		show_header = false,
		column_gap = 2,
		fill = true,
		cell_hl = function(row, col)
			if col.key == "k1" or col.key == "k2" then
				local label = col.key == "k1" and row.k1 or row.k2
				if label == "" then
					return nil
				end
				return {
					{ start_col = 0, end_col = #label, hl_group = "AtlasTextMuted" },
				}
			end

			if col.key == "v1" and row.v1 ~= "" then
				return {
					{ start_col = 0, end_col = #row.v1, hl_group = row.v1_hl },
				}
			end

			if col.key == "v2" and row.v2 ~= "" then
				return {
					{ start_col = 0, end_col = #row.v2, hl_group = row.v2_hl },
				}
			end

			return nil
		end,
	})

	local labels_key = "Labels:"
	local labels_prefix = labels_key .. "  "
	local labels_segments = {} -- list of { start_col, end_col, hl_group }
	local labels_line

	if type(state.fields.labels) == "table" and #state.fields.labels > 0 then
		local cursor = #labels_prefix
		local pieces = {}
		for i, l in ipairs(state.fields.labels) do
			local name = tostring(l.name or "")
			if name ~= "" then
				if i > 1 then
					table.insert(pieces, " ")
					cursor = cursor + 1
				end
				local chip = " " .. name .. " "
				table.insert(pieces, chip)
				table.insert(labels_segments, {
					start_col = cursor,
					end_col = cursor + #chip,
					hl_group = label_hl(l.color),
				})
				cursor = cursor + #chip
			end
		end
		labels_line = labels_prefix .. table.concat(pieces)
	else
		labels_line = labels_prefix .. "None"
		table.insert(labels_segments, {
			start_col = #labels_prefix,
			end_col = #labels_line,
			hl_group = "AtlasTextMuted",
		})
	end

	local labels_line_idx = #lines
	table.insert(lines, labels_line)

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

	vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

	for _, span in ipairs(spans or {}) do
		pcall(vim.api.nvim_buf_set_extmark, buf, NS, span.line, span.start_col, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end

	pcall(vim.api.nvim_buf_set_extmark, buf, NS, labels_line_idx, 0, {
		end_col = #labels_key,
		hl_group = "AtlasTextMuted",
	})
	for _, seg in ipairs(labels_segments) do
		pcall(vim.api.nvim_buf_set_extmark, buf, NS, labels_line_idx, seg.start_col, {
			end_col = seg.end_col,
			hl_group = seg.hl_group,
		})
	end
end

return M
