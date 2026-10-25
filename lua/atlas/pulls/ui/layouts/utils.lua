local icons = require("atlas.ui.shared.icons")
local presentation = require("atlas.pulls.ui.presentation")
local stack = require("atlas.pulls.stack")
local table_tree = require("atlas.ui.components.table_tree")
local utils = require("atlas.ui.shared.utils")

local M = {}

local STAR_ICON, STAR_HIGHLIGHT = icons.get("star")
local STATE_ICONS = {
	open = { icons.get("pr") },
	draft = { icons.get("draft_pr") },
	merged = { icons.get("merged_pr") },
	declined = { icons.get("declined_pr") },
}

---@param pr PullRequest
---@param opts table
---@return string, string
function M.pull_icon(pr, opts)
	local key = pr.repo_full_name .. ":" .. tostring(pr.id)
	if opts.reloading and opts.reloading[key] then
		return opts.spinner or "⠋", "AtlasTextMuted"
	end

	local style = STATE_ICONS[pr.state]
	return style[1], style[2]
end

---@param pulls PullRequest[]
---@return PullRequest[]
function M.starred_first(pulls)
	local starred, rest = {}, {}

	for _, pr in ipairs(pulls) do
		table.insert(pr.is_starred and starred or rest, pr)
	end

	return vim.list_extend(starred, rest)
end

---@param pr PullRequest
---@param reference string
---@return string
function M.title(pr, reference)
	local title = (pr.is_starred and STAR_ICON .. " " or "") .. reference .. tostring(pr.id) .. " " .. pr.title
	local indicator = stack.indicator(pr.stack)
	if indicator then
		title = title .. "  " .. indicator
	end
	return title
end

---@param pr PullRequest
---@return string
function M.author(pr)
	return string.format("%s %s", icons.get("user"), utils.shorten_name(presentation.user_handle(pr.author), 20))
end

---@param additions number
---@param deletions number
---@return string, table[]
function M.diff_stats(additions, deletions)
	if additions + deletions == 0 then
		return "", {}
	end

	local added = "+" .. tostring(additions)
	local text = added .. " -" .. tostring(deletions)

	return text,
		{
			{ start_col = 0, end_col = #added, hl_group = "AtlasTextPositive" },
			{ start_col = #added + 1, end_col = #text, hl_group = "AtlasLogError" },
		}
end

---@param status string|nil
---@return string, string
function M.status_icon(status)
	if status then
		return icons.get(status, "status")
	end

	return icons.get("inprogress", "status"), "AtlasTextMuted"
end

local function cell_highlights(row, column, context, opts)
	local pr = row.kind == "pr" and row._item.pr or nil
	if column.key == "name" and row.kind == "repo" then
		local name_end = math.min(#row._item.repo.full_name, #context.text)
		return {
			{ start_col = 0, end_col = name_end, hl_group = "AtlasColumnHeader" },
			{ start_col = name_end, end_col = #context.text, hl_group = "AtlasTextMuted" },
		}
	end

	if (column.key == "name" or column.key == "repo_pr") and pr then
		local icon, icon_hl = M.pull_icon(pr, opts)
		local spans = { { start_col = 0, end_col = #icon, hl_group = icon_hl } }

		if context.text:find(icon .. " " .. STAR_ICON .. " ", 1, true) == 1 then
			table.insert(spans, { start_col = #icon + 1, end_col = #icon + 1 + #STAR_ICON, hl_group = STAR_HIGHLIGHT })
		end

		local indicator = stack.indicator(pr.stack)
		if indicator then
			local start_col = context.text:find(indicator, 1, true)
			if start_col then
				table.insert(spans, {
					start_col = start_col - 1,
					end_col = start_col - 1 + #indicator,
					hl_group = "AtlasTextMuted",
				})
			end
		end

		return spans
	end

	if column.key == "created" or column.key == "updated" or (row.kind == "meta" and column.key == "repo_pr") then
		return "AtlasTextMuted"
	end

	if column.key == "author" then
		return presentation.author_hl(pr and presentation.user_handle(pr.author))
	end
end

local function reference_highlights(lines, line_map, spans, reference)
	for line_number, item in pairs(line_map) do
		if item.kind == "pr" then
			local start_col, end_col = lines[line_number]:find(reference .. tostring(item.pr.id), 1, true)

			if start_col then
				table.insert(spans, {
					line = line_number - 1,
					start_col = start_col - 1,
					end_col = end_col,
					hl_group = "AtlasTextMuted",
				})
			end
		end
	end
end

---@param opts table
---@param rows table[]
---@param columns table[]
---@param highlights? fun(row: table, column: table, context: table): string|table[]|nil
---@param reference string
---@return string[], table<integer, table>, table[]
function M.render(opts, rows, columns, highlights, reference)
	local lines, line_map, spans = table_tree.render({
		width = opts.width,
		margin = 1,
		columns = columns,
		rows = rows,
		hide_columns = { "diff", "author", "created", "updated" },
		cell_hl = function(row, column, context)
			return highlights and highlights(row, column, context) or cell_highlights(row, column, context, opts)
		end,
	})

	reference_highlights(lines, line_map, spans, reference)

	return lines, line_map, spans
end

return M
