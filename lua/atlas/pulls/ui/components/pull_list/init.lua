local icons = require("atlas.ui.shared.icons")
local presentation = require("atlas.pulls.ui.presentation")
local providers = require("atlas.pulls.ui.components.pull_list.providers")
local table_tree = require("atlas.ui.components.table_tree")
local utils = require("atlas.ui.shared.utils")

local M = {}

local PR_ICON, PR_ICON_HL = icons.pulls("pr")
local MERGED_PR_ICON, MERGED_PR_ICON_HL = icons.pulls("merged_pr")
local DECLINED_PR_ICON, DECLINED_PR_ICON_HL = icons.pulls("declined_pr")
local STAR_ICON, STAR_ICON_HL = icons.general("star")

local PR_STATE_ICON = {
	open = { PR_ICON, PR_ICON_HL },
	draft = { PR_ICON, "AtlasPRDraft" },
	merged = { MERGED_PR_ICON, MERGED_PR_ICON_HL },
	declined = { DECLINED_PR_ICON, DECLINED_PR_ICON_HL },
}

---@param pr PullRequest
---@param opts table
---@return string, string
local function pr_icon(pr, opts)
	local key = pr.repo_full_name .. ":" .. tostring(pr.id)
	if opts.reloading and opts.reloading[key] then
		return opts.spinner or "⠋", "AtlasTextMuted"
	end
	local style = PR_STATE_ICON[pr.state]
	return style[1], style[2]
end

---@param pulls PullRequest[]
---@return PullRequest[]
local function starred_first(pulls)
	local starred, rest = {}, {}
	for _, pr in ipairs(pulls) do
		table.insert(pr.is_starred and starred or rest, pr)
	end
	return vim.list_extend(starred, rest)
end

---@param pulls PullRequest[]
---@return { repo: AtlasRepository, pulls: PullRequest[] }[]
local function group_by_repo(pulls)
	local groups, by_repo = {}, {}
	for _, pr in ipairs(pulls) do
		local group = by_repo[pr.repo_full_name]
		if group == nil then
			group = { repo = pr.repo, pulls = {} }
			by_repo[pr.repo_full_name] = group
			table.insert(groups, group)
		end
		table.insert(group.pulls, pr)
	end
	return groups
end

---@param row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@param display table
---@return table[]|nil
local function cell_hl(row, col, ctx, display)
	local provider_hl = display.highlight(row, col, ctx)
	if provider_hl ~= nil then
		return provider_hl
	end
	if col.key == "repo_pr" and ctx.text:find(STAR_ICON, 1, true) == 1 then
		return { { start_col = 0, end_col = #STAR_ICON, hl_group = STAR_ICON_HL } }
	end
	if col.key == "name" and row.kind == "repo" then
		return { { start_col = 0, end_col = #ctx.text, hl_group = "AtlasSectionHeader" } }
	end
	if col.key == "name" and row.kind == "pr" then
		local icon_hl = row._pr_icon_hl or "AtlasPROpen"
		local icon = row._pr_icon_str or PR_ICON
		local spans = {}
		if ctx.text:find(icon .. " " .. STAR_ICON .. " ", 1, true) == 1 then
			table.insert(spans, {
				start_col = #icon + 1,
				end_col = #icon + 1 + #STAR_ICON,
				hl_group = STAR_ICON_HL,
			})
		end
		local start = ctx.text:find(icon, 1, true)
		if start ~= nil then
			start = start - 1
			table.insert(spans, { start_col = start, end_col = start + #icon, hl_group = icon_hl })
		end
		return spans
	end
	if col.key == "pr_icon" then
		local hl = row.kind == "pr" and row._pr_icon_hl or "AtlasTextMuted"
		return { { start_col = 0, end_col = #ctx.padded, hl_group = hl } }
	end
	if col.key == "created" or col.key == "updated" or (row.kind == "meta" and col.key == "repo_pr") then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
	end
	if col.key == "author" then
		return {
			{
				start_col = 0,
				end_col = #ctx.padded,
				hl_group = presentation.author_hl(row.author_hl or row.author),
			},
		}
	end
end

---@param row table
---@param values table
local function add_values(row, values)
	for key, value in pairs(values) do
		row[key] = value
	end
end

---@param pulls PullRequest[]
---@param display table
---@param opts table
---@return table[]
local function compact_rows(pulls, display, opts)
	local rows = {}
	for _, pr in ipairs(pulls) do
		local repo = pr.repo
		local icon, icon_hl = pr_icon(pr, opts)
		local author = presentation.user_handle(pr.author)
		local row = {
			kind = "pr",
			pr_icon = icon,
			_pr_icon_str = icon,
			_pr_icon_hl = icon_hl,
			repo_pr = (pr.is_starred and STAR_ICON .. " " or "")
				.. display.reference
				.. tostring(pr.id)
				.. " "
				.. pr.title,
			conversation = tostring(pr.comments_count),
			author = string.format("%s %s", icons.general("user"), utils.shorten_name(author, 20)),
			author_hl = author,
			created = utils.relative_time(pr.created_on),
			updated = utils.relative_time(pr.updated_on),
			_item = { kind = "pr", id = pr.id, repo = repo, pr = pr },
		}
		add_values(row, display.values(pr))
		table.insert(rows, row)
		table.insert(rows, {
			kind = "meta",
			pr_icon = "",
			repo_pr = repo.full_name,
			separator = true,
			_item = { kind = "pr_meta", id = pr.id, repo = repo, pr = pr },
		})
	end
	return rows
end

---@param pulls PullRequest[]
---@param grouped boolean
---@param display table
---@param opts table
---@return table[]
local function list_rows(pulls, grouped, display, opts)
	local groups = grouped and group_by_repo(pulls) or {}
	if not grouped then
		for _, pr in ipairs(pulls) do
			table.insert(groups, { repo = pr.repo, pulls = { pr } })
		end
	end

	local rows = {}
	for group_index, group in ipairs(groups) do
		if grouped then
			if group_index > 1 then
				table.insert(rows, { kind = "spacer" })
			end
			table.insert(rows, {
				kind = "repo",
				name = group.repo.full_name,
				_item = { kind = "repo", repo = group.repo },
			})
			table.insert(rows, { kind = "spacer" })
		end
		for pr_index, pr in ipairs(group.pulls) do
			if not grouped and #rows > 0 then
				table.insert(rows, { kind = "spacer" })
			end
			local repo = group.repo
			local icon, icon_hl = pr_icon(pr, opts)
			local author = presentation.user_handle(pr.author)
			local row = {
				kind = "pr",
				_pr_icon_str = icon,
				_pr_icon_hl = icon_hl,
				name = icon .. " " .. (pr.is_starred and STAR_ICON .. " " or "") .. display.reference .. tostring(
					pr.id
				) .. " " .. pr.title,
				conversation = tostring(pr.comments_count),
				author = string.format("%s %s", icons.general("user"), utils.shorten_name(author, 20)),
				author_hl = author,
				created = utils.relative_time(pr.created_on),
				updated = utils.relative_time(pr.updated_on),
				_item = { kind = "pr", id = pr.id, repo = repo, pr = pr },
			}
			add_values(row, display.values(pr))
			table.insert(rows, row)
			if grouped and pr_index < #group.pulls then
				table.insert(rows, { kind = "spacer" })
			end
		end
	end
	return rows
end

---@param opts { width: integer, provider_id?: string, layout?: AtlasPullsViewLayout, reloading?: table<string, boolean>, spinner?: string }
---@param pulls PullRequest[]
---@return string[], table<integer, table>, table[]
function M.render(opts, pulls)
	local display = providers.get(opts.provider_id)
	local layout = opts.layout or "compact"
	local compact = layout ~= "grouped" and layout ~= "plain"
	pulls = starred_first(pulls)
	local lines, line_map, spans = table_tree.render({
		width = opts.width,
		margin = 1,
		columns = compact and display.columns.compact or display.columns.list,
		rows = compact and compact_rows(pulls, display, opts) or list_rows(pulls, layout == "grouped", display, opts),
		hide_columns = { "diff", "author", "created", "updated" },
		cell_hl = function(row, col, ctx)
			return cell_hl(row, col, ctx, display)
		end,
	})
	for lnum, item in pairs(line_map) do
		if item.kind == "pr" then
			local reference = display.reference .. tostring(item.pr.id)
			local start, finish = lines[lnum]:find(reference, 1, true)
			if start ~= nil then
				table.insert(spans, {
					line = lnum - 1,
					start_col = start - 1,
					end_col = finish,
					hl_group = "AtlasTextMuted",
				})
			end
		end
	end
	return lines, line_map, spans
end

return M
