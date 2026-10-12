local icons = require("atlas.ui.shared.icons")
local presentation = require("atlas.pulls.ui.presentation")
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

local function pull_icon(pr, opts)
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
	return (pr.is_starred and STAR_ICON .. " " or "") .. reference .. tostring(pr.id) .. " " .. pr.title
end

---@param pr PullRequest
---@param opts table
---@param values? fun(pr: PullRequest): table
---@return table
function M.pull_row(pr, opts, values)
	local icon, hl_group = pull_icon(pr, opts)
	local author = presentation.user_handle(pr.author)
	local row = {
		kind = "pr",
		_pr_icon_str = icon,
		_pr_icon_hl = hl_group,
		conversation = tostring(pr.comments_count),
		author = string.format("%s %s", icons.get("user"), utils.shorten_name(author, 20)),
		author_hl = author,
		created = utils.relative_time(pr.created_on),
		updated = utils.relative_time(pr.updated_on),
		_item = { kind = "pr", id = pr.id, repo = pr.repo, pr = pr },
	}

	for key, value in pairs(values and values(pr) or {}) do
		row[key] = value
	end

	return row
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

local function cell_highlights(row, column, context)
	if column.key == "repo_pr" and context.text:find(STAR_ICON, 1, true) == 1 then
		return { { start_col = 0, end_col = #STAR_ICON, hl_group = STAR_HIGHLIGHT } }
	end

	if column.key == "name" and row.kind == "repo" then
		return { { start_col = 0, end_col = #context.text, hl_group = "AtlasSectionHeader" } }
	end

	if column.key == "name" and row.kind == "pr" then
		local icon = row._pr_icon_str
		local spans = { { start_col = 0, end_col = #icon, hl_group = row._pr_icon_hl } }

		if context.text:find(icon .. " " .. STAR_ICON .. " ", 1, true) == 1 then
			table.insert(spans, { start_col = #icon + 1, end_col = #icon + 1 + #STAR_ICON, hl_group = STAR_HIGHLIGHT })
		end

		return spans
	end

	if column.key == "pr_icon" then
		return row.kind == "pr" and row._pr_icon_hl or "AtlasTextMuted"
	end

	if column.key == "created" or column.key == "updated" or (row.kind == "meta" and column.key == "repo_pr") then
		return "AtlasTextMuted"
	end

	if column.key == "author" then
		return presentation.author_hl(row.author_hl)
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
			return highlights and highlights(row, column, context) or cell_highlights(row, column, context)
		end,
	})

	reference_highlights(lines, line_map, spans, reference)

	return lines, line_map, spans
end

return M
