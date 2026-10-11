local icons = require("atlas.ui.shared.icons")
local presentation = require("atlas.pulls.ui.presentation")
local table_tree = require("atlas.ui.components.table_tree")
local utils = require("atlas.ui.shared.utils")

local M = {}

local STAR_ICON, STAR_HIGHLIGHT = icons.general("star")
local STATE_ICONS = {
	open = { icons.pulls("pr") },
	draft = { icons.pulls("draft_pr") },
	merged = { icons.pulls("merged_pr") },
	declined = { icons.pulls("declined_pr") },
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
---@param repo AtlasRepository
---@param opts table
---@return table
function M.pull_row(pr, repo, opts)
	local icon, hl_group = pull_icon(pr, opts)
	local author = presentation.user_handle(pr.author)

	return {
		kind = "pr",
		_pr_icon_str = icon,
		_pr_icon_hl = hl_group,
		conversation = tostring(pr.comments_count),
		author = string.format("%s %s", icons.general("user"), utils.shorten_name(author, 20)),
		author_hl = author,
		created = utils.relative_time(pr.created_on),
		updated = utils.relative_time(pr.updated_on),
		_item = { kind = "pr", id = pr.id, repo = repo, pr = pr },
	}
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
		local spans = {}

		if context.text:find(icon .. " " .. STAR_ICON .. " ", 1, true) == 1 then
			table.insert(spans, {
				start_col = #icon + 1,
				end_col = #icon + 1 + #STAR_ICON,
				hl_group = STAR_HIGHLIGHT,
			})
		end

		local start_col = context.text:find(icon, 1, true)
		if start_col then
			table.insert(spans, {
				start_col = start_col - 1,
				end_col = start_col - 1 + #icon,
				hl_group = row._pr_icon_hl,
			})
		end

		return spans
	end

	if column.key == "pr_icon" then
		local hl_group = row.kind == "pr" and row._pr_icon_hl or "AtlasTextMuted"
		return { { start_col = 0, end_col = #context.padded, hl_group = hl_group } }
	end

	if column.key == "created" or column.key == "updated" or (row.kind == "meta" and column.key == "repo_pr") then
		return { { start_col = 0, end_col = #context.padded, hl_group = "AtlasTextMuted" } }
	end

	if column.key == "author" then
		return {
			{
				start_col = 0,
				end_col = #context.padded,
				hl_group = presentation.author_hl(row.author_hl),
			},
		}
	end
end

local function reference_highlights(lines, line_map, spans, reference)
	for line_number, item in pairs(line_map) do
		if item.kind == "pr" then
			local label = reference .. tostring(item.pr.id)
			local start_col, end_col = lines[line_number]:find(label, 1, true)

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

---@return string[], table<integer, table>, table[]
function M.render(opts, rows, columns, highlights, reference)
	local lines, line_map, spans = table_tree.render({
		width = opts.width,
		margin = 1,
		columns = columns,
		rows = rows,
		hide_columns = { "diff", "author", "created", "updated" },
		cell_hl = function(row, column, context)
			return highlights(row, column, context) or cell_highlights(row, column, context)
		end,
	})

	reference_highlights(lines, line_map, spans, reference)

	return lines, line_map, spans
end

return M
