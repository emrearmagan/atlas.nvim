local M = {}

local helper = require("atlas.pulls.ui.main.helper")
local table_tree = require("atlas.ui.components.table_tree")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local state = require("atlas.pulls.state")

local PR_ICON, PR_ICON_HL = icons.pulls("pr")
local MERGED_PR_ICON, MERGED_PR_ICON_HL = icons.pulls("merged_pr")
local DECLINED_PR_ICON, DECLINED_PR_ICON_HL = icons.pulls("declined_pr")
local STAR_ICON = icons.general("star")

---@param additions number
---@param deletions number
---@return string, table[]
local function diff_stats(additions, deletions)
	if additions + deletions == 0 then
		return "", {}
	end

	local add_text = "+" .. tostring(additions)
	local del_text = "-" .. tostring(deletions)
	local text = add_text .. " " .. del_text
	return text,
		{
			{ start_col = 0, end_col = #add_text, hl_group = "AtlasTextPositive" },
			{ start_col = #add_text + 1, end_col = #text, hl_group = "AtlasLogError" },
		}
end

local PR_STATE_ICON = {
	open = { PR_ICON, PR_ICON_HL },
	draft = { PR_ICON, "AtlasPRDraft" },
	merged = { MERGED_PR_ICON, MERGED_PR_ICON_HL },
	declined = { DECLINED_PR_ICON, DECLINED_PR_ICON_HL },
}

---@param pr PullRequest
---@return string, string
local function pr_icon_and_hl(pr)
	local s = tostring(pr.state or ""):lower()
	local style = PR_STATE_ICON[s] or PR_STATE_ICON.open
	return style[1], style[2]
end

local CI_ICON = {
	SUCCESS = { icons.pulls_status("successful") },
	FAILURE = { icons.pulls_status("failed") },
	ERROR = { icons.pulls_status("failed") },
	PENDING = { icons.pulls_status("inprogress") },
	EXPECTED = { icons.pulls_status("inprogress") },
}

local REVIEW_ICON = {
	APPROVED = { icons.pulls_status("successful") },
	CHANGES_REQUESTED = { icons.pulls_status("inprogress") },
	REVIEW_REQUIRED = { icons.pulls_status("inprogress") },
}

REVIEW_ICON.CHANGES_REQUESTED[2] = "AtlasTextWarning"
REVIEW_ICON.REVIEW_REQUIRED[2] = "AtlasTextMuted"

---@param pr PullRequest
---@return string, string
local function ci_icon_and_hl(pr)
	local ok, rollup_state = pcall(function()
		return pr._raw.commits.nodes[1].commit.statusCheckRollup.state
	end)
	if not ok or type(rollup_state) ~= "string" then
		local icon = icons.pulls_status("inprogress")
		return icon, "AtlasTextMuted"
	end
	local s = rollup_state:upper()
	local style = CI_ICON[s]
	if not style then
		local icon = icons.pulls_status("inprogress")
		return icon, "AtlasTextMuted"
	end
	return style[1], style[2]
end

---@param pr PullRequest
---@return string, string
local function review_icon_and_hl(pr)
	if pr.reviewers == nil then
		return REVIEW_ICON.REVIEW_REQUIRED[1], REVIEW_ICON.REVIEW_REQUIRED[2]
	end
	local approved, changes = 0, 0
	for _, reviewer in ipairs(pr.reviewers) do
		if reviewer.decision == "approved" then
			approved = approved + 1
		elseif reviewer.decision == "changes_requested" then
			changes = changes + 1
		end
	end
	if changes > 0 then
		return REVIEW_ICON.CHANGES_REQUESTED[1], REVIEW_ICON.CHANGES_REQUESTED[2]
	end
	if approved > 0 then
		return REVIEW_ICON.APPROVED[1], REVIEW_ICON.APPROVED[2]
	end
	return REVIEW_ICON.REVIEW_REQUIRED[1], REVIEW_ICON.REVIEW_REQUIRED[2]
end

---@param row table
---@param col table
---@param ctx table
---@return table[]|nil
local function cell_hl(row, col, ctx)
	if col.key == "ci" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = row.ci_hl or "AtlasTextMuted" } }
	end
	if col.key == "review" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = row.review_hl or "AtlasTextMuted" } }
	end
	if col.key == "diff" and row.kind == "pr" then
		return row.diff_hl
	end
	return helper.cell_hl(row, col, ctx)
end

---@param pr PullRequest
---@return string
local function pr_icon_or_spinner(pr)
	if state.is_pr_reloading(pr.repo_full_name, pr.id) then
		return state.reload_spinner_frame or "⠋"
	end
	local icon = pr_icon_and_hl(pr)
	return icon
end

---@param lines string[]
---@param map table<integer, table>
---@param spans table[]
---@param layout "compact"|"grouped"|"plain"
local function add_pr_reference_spans(lines, map, spans, layout)
	for lnum, item in pairs(map or {}) do
		if item.kind == "pr" then
			local line = lines[lnum] or ""
			local reference = (layout == "plain" and item.pr.repo_full_name or "") .. "#" .. tostring(item.pr.id)
			local s, e = string.find(line, reference, 1, true)
			if s and e then
				table.insert(spans, {
					line = lnum - 1,
					start_col = s - 1,
					end_col = e,
					hl_group = "AtlasTextMuted",
				})
			end
		end
	end
end

-- Compact layout

---@return table[]
local function compact_columns()
	return {
		{ key = "pr_icon", name = "", min_width = 1, can_grow = false, header_hl = "AtlasColumnHeader" },
		{ key = "repo_pr", name = "Title", min_width = 42, header_hl = "AtlasColumnHeader" },
		{
			key = "conversation",
			name = icons.general("conversation"),
			min_width = 2,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{ key = "ci", name = icons.pulls("tasks"), min_width = 1, can_grow = false, header_hl = "AtlasColumnHeader" },
		{
			key = "review",
			name = icons.general("success"),
			min_width = 1,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{
			key = "author",
			name = string.format("%s Author", icons.general("user")),
			min_width = 3,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{
			key = "diff",
			name = icons.pulls("changes"),
			max_width = 15,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{ key = "created", name = icons.general("created"), can_grow = false, header_hl = "AtlasColumnHeader" },
		{ key = "updated", name = icons.general("updated"), can_grow = false, header_hl = "AtlasColumnHeader" },
	}
end

---@param pulls PullRequest[]
---@return table[]
local function compact_rows(pulls)
	local rows = {}
	for _, pr in ipairs(pulls) do
		local repo = helper.repo(pr)
		local id_str = tostring(pr.id or "")
		local title = tostring(pr.title or "")
		local author_name = helper.user_handle(pr.author)
		local is_reloading = state.is_pr_reloading(pr.repo_full_name, pr.id)
		local ci, ci_h = ci_icon_and_hl(pr)
		local review, review_h = review_icon_and_hl(pr)
		local diff_text, diff_highlights = diff_stats(pr.lines_added or 0, pr.lines_removed or 0)
		local icon, icon_hl = pr_icon_and_hl(pr)
		table.insert(rows, {
			kind = "pr",
			pr_icon = pr_icon_or_spinner(pr),
			_pr_reloading = is_reloading,
			_pr_icon_str = icon,
			_pr_icon_hl = icon_hl,
			repo_pr = (pr.is_starred and STAR_ICON .. " " or "") .. "#" .. id_str .. " " .. title,
			conversation = tostring(pr.comments_count or 0),
			ci = ci,
			ci_hl = ci_h,
			review = review,
			review_hl = review_h,
			diff = diff_text,
			diff_hl = diff_highlights,
			author = string.format("%s %s", icons.general("user"), utils.shorten_name(author_name, 20)),
			author_hl = author_name,
			created = utils.relative_time(pr.created_on),
			updated = utils.relative_time(pr.updated_on),
			_item = { kind = "pr", id = pr.id, repo = repo, pr = pr },
		})
		table.insert(rows, {
			kind = "meta",
			pr_icon = "",
			repo_pr = repo.name,
			conversation = "",
			ci = "",
			ci_hl = "",
			review = "",
			review_hl = "",
			diff = "",
			diff_hl = nil,
			author = "",
			created = "",
			updated = "",
			separator = true,
			_item = { kind = "pr_meta", id = pr.id, repo = repo, pr = pr },
		})
	end
	return rows
end

-- Grouped and plain layouts

---@return table[]
local function list_columns()
	return {
		{ key = "name", name = "Title", min_width = 42, header_hl = "AtlasColumnHeader" },
		{
			key = "conversation",
			name = icons.general("conversation"),
			min_width = 2,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{ key = "ci", name = icons.pulls("tasks"), min_width = 1, can_grow = false, header_hl = "AtlasColumnHeader" },
		{
			key = "review",
			name = icons.general("success"),
			min_width = 1,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{
			key = "author",
			name = string.format("%s Author", icons.general("user")),
			min_width = 3,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{
			key = "diff",
			name = icons.pulls("changes"),
			max_width = 15,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{ key = "created", name = icons.general("created"), can_grow = false, header_hl = "AtlasColumnHeader" },
		{ key = "updated", name = icons.general("updated"), can_grow = false, header_hl = "AtlasColumnHeader" },
	}
end

---@param pulls PullRequest[]
---@param layout "grouped"|"plain"
---@return table[]
local function list_rows(pulls, layout)
	local rows = {}
	local grouped = layout == "grouped"
	local sections = {}
	if grouped then
		sections = helper.group_by_repo(pulls)
	else
		for _, pr in ipairs(pulls) do
			table.insert(sections, { repo = helper.repo(pr), pulls = { pr } })
		end
	end
	for i, section in ipairs(sections) do
		if grouped then
			if i > 1 then
				table.insert(rows, { kind = "spacer" })
			end
			table.insert(rows, {
				kind = "repo",
				name = section.repo.name,
				conversation = "",
				ci = "",
				ci_hl = "",
				review = "",
				review_hl = "",
				diff = "",
				diff_hl = nil,
				author = "",
				created = "",
				updated = "",
				_item = { kind = "repo", repo = section.repo },
			})
			table.insert(rows, { kind = "spacer" })
		end
		for pr_index, pr in ipairs(section.pulls) do
			if not grouped and #rows > 0 then
				table.insert(rows, { kind = "spacer" })
			end
			local id_str = tostring(pr.id or "")
			local title = tostring(pr.title or "")
			local reference = (grouped and "" or pr.repo_full_name) .. "#" .. id_str
			local author_name = helper.user_handle(pr.author)
			local icon = pr_icon_or_spinner(pr)
			local _, icon_hl = pr_icon_and_hl(pr)
			local ci, ci_h = ci_icon_and_hl(pr)
			local review, review_h = review_icon_and_hl(pr)
			local diff_text, diff_highlights = diff_stats(pr.lines_added or 0, pr.lines_removed or 0)
			table.insert(rows, {
				kind = "pr",
				_pr_reloading = state.is_pr_reloading(pr.repo_full_name, pr.id),
				_pr_icon_str = icon,
				_pr_icon_hl = icon_hl,
				name = icon .. " " .. (pr.is_starred and STAR_ICON .. " " or "") .. reference .. " " .. title,
				conversation = tostring(pr.comments_count or 0),
				ci = ci,
				ci_hl = ci_h,
				review = review,
				review_hl = review_h,
				diff = diff_text,
				diff_hl = diff_highlights,
				author = string.format("%s %s", icons.general("user"), utils.shorten_name(author_name, 20)),
				author_hl = author_name,
				created = utils.relative_time(pr.created_on),
				updated = utils.relative_time(pr.updated_on),
				_item = { kind = "pr", id = pr.id, repo = section.repo, pr = pr },
			})
			if grouped and pr_index < #section.pulls then
				table.insert(rows, { kind = "spacer" })
			end
		end
	end
	return rows
end

-- Render

---@param pulls PullRequest[]
---@param layout "compact"|"grouped"|"plain"
---@param opts { width: integer }
---@return PullsMainRenderResult
function M.render(pulls, layout, opts)
	local lines = {}
	local spans = {}

	local tbl_lines, tbl_map, tbl_spans

	if layout == "grouped" or layout == "plain" then
		tbl_lines, tbl_map, tbl_spans = table_tree.render({
			width = opts.width,
			margin = 1,
			columns = list_columns(),
			rows = list_rows(pulls, layout),
			cell_hl = cell_hl,
		})
	else
		tbl_lines, tbl_map, tbl_spans = table_tree.render({
			width = opts.width,
			margin = 1,
			columns = compact_columns(),
			rows = compact_rows(pulls),
			cell_hl = cell_hl,
		})
	end

	add_pr_reference_spans(tbl_lines, tbl_map, tbl_spans, layout)

	local base = #lines
	for _, line in ipairs(tbl_lines) do
		table.insert(lines, line)
	end
	for _, span in ipairs(tbl_spans) do
		span.line = span.line + base
		table.insert(spans, span)
	end
	local line_map = {}
	for lnum, node in pairs(tbl_map) do
		line_map[lnum + base] = node
	end

	return { lines = lines, spans = spans, line_map = line_map }
end

return M
