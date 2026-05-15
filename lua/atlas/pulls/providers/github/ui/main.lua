local M = {}

local helper = require("atlas.pulls.ui.main.helper")
local table_tree = require("atlas.ui.components.table_tree")
local diff_blocks = require("atlas.ui.components.diff_blocks")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local state = require("atlas.pulls.state")

local PR_ICON = icons.pulls("pr")
local MERGED_PR_ICON = icons.pulls("merged_pr")
local DECLINED_PR_ICON = icons.pulls("declined_pr")
local REPO_ICON = icons.pulls("repo")

local PR_STATE_ICON = {
	open = PR_ICON,
	draft = PR_ICON,
	merged = MERGED_PR_ICON,
	declined = DECLINED_PR_ICON,
}

local PR_STATE_ICON_HL = {
	open = "AtlasPROpen",
	draft = "AtlasPRDraft",
	merged = "AtlasPRMerged",
	declined = "AtlasPRDeclined",
}

---@param pr PullRequest
---@return string, string
local function pr_icon_and_hl(pr)
	local s = tostring(pr.state or ""):lower()
	return PR_STATE_ICON[s] or PR_ICON, PR_STATE_ICON_HL[s] or "AtlasPROpen"
end

local CI_ICON = {
	SUCCESS = icons.pulls_status("successful"),
	FAILURE = icons.pulls_status("failed"),
	ERROR = icons.pulls_status("failed"),
	PENDING = icons.pulls_status("inprogress"),
	EXPECTED = icons.pulls_status("inprogress"),
}

local CI_HL = {
	SUCCESS = "AtlasTextPositive",
	FAILURE = "AtlasLogError",
	ERROR = "AtlasLogError",
	PENDING = "AtlasTextWarning",
	EXPECTED = "AtlasTextWarning",
}

local REVIEW_ICON = {
	APPROVED = icons.pulls_status("successful"),
	CHANGES_REQUESTED = icons.pulls_status("inprogress"),
	REVIEW_REQUIRED = icons.pulls_status("inprogress"),
}

local REVIEW_HL = {
	APPROVED = "AtlasTextPositive",
	CHANGES_REQUESTED = "AtlasTextWarning",
	REVIEW_REQUIRED = "AtlasTextMuted",
}

---@param pr PullRequest
---@return string, string
local function ci_icon_and_hl(pr)
	local ok, rollup_state = pcall(function()
		return pr._raw.commits.nodes[1].commit.statusCheckRollup.state
	end)
	if not ok or type(rollup_state) ~= "string" then
		return icons.pulls_status("inprogress"), "AtlasTextMuted"
	end
	local s = rollup_state:upper()
	return CI_ICON[s] or icons.pulls_status("inprogress"), CI_HL[s] or "AtlasTextMuted"
end

---@param pr PullRequest
---@return string, string
local function review_icon_and_hl(pr)
	local ok, nodes = pcall(function()
		return pr._raw.latestOpinionatedReviews.nodes
	end)
	if not ok or type(nodes) ~= "table" then
		return REVIEW_ICON.REVIEW_REQUIRED, REVIEW_HL.REVIEW_REQUIRED
	end
	local approved, changes = 0, 0
	for _, node in ipairs(nodes) do
		local s = tostring(node.state or ""):upper()
		if s == "APPROVED" then approved = approved + 1
		elseif s == "CHANGES_REQUESTED" then changes = changes + 1
		end
	end
	if changes > 0 then
		return REVIEW_ICON.CHANGES_REQUESTED, REVIEW_HL.CHANGES_REQUESTED
	end
	if approved > 0 then
		return REVIEW_ICON.APPROVED, REVIEW_HL.APPROVED
	end
	return REVIEW_ICON.REVIEW_REQUIRED, REVIEW_HL.REVIEW_REQUIRED
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
local function add_pr_id_spans(lines, map, spans)
	for lnum, item in pairs(map or {}) do
		if type(item) == "table" and item.kind == "pr" then
			local line = lines[lnum] or ""
			local s, e = string.find(line, "#%d+")
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
		{ key = "repo_pr", name = "PR", min_width = 42, header_hl = "AtlasColumnHeader" },
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
			key = "repo",
			name = string.format("%s Repo", REPO_ICON),
			min_width = 5,
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

---@param groups PullsGroup[]
---@return table[]
local function compact_rows(groups)
	local rows = {}
	for _, group in ipairs(groups or {}) do
		local repo_label = group.repo.name or ""
		for _, pr in ipairs(group.prs or {}) do
			local id_str = tostring(pr.id or "")
			local title = tostring(pr.title or "")
			local author_name = (pr.author and pr.author.name) and pr.author.name or ""
			local src = (pr.source and pr.source.branch) or ""
			local dst = (pr.destination and pr.destination.branch) or ""
			local is_reloading = state.is_pr_reloading(pr.repo_full_name, pr.id)
			local ci, ci_h = ci_icon_and_hl(pr)
			local review, review_h = review_icon_and_hl(pr)
			local diff_result = diff_blocks.render({
				additions = tonumber(pr._raw and pr._raw.additions) or 0,
				deletions = tonumber(pr._raw and pr._raw.deletions) or 0,
				show_count = false,
			})
			local icon, icon_hl = pr_icon_and_hl(pr)
			table.insert(rows, {
				kind = "pr",
				pr_icon = pr_icon_or_spinner(pr),
				_pr_reloading = is_reloading,
				_pr_icon_str = icon,
				_pr_icon_hl = icon_hl,
				repo_pr = "#" .. id_str .. " " .. title,
				conversation = tostring(pr.comments_count or 0),
				ci = ci,
				ci_hl = ci_h,
				review = review,
				review_hl = review_h,
				diff = diff_result.text,
				diff_hl = diff_result.highlights,
				author = string.format("%s %s", icons.general("user"), utils.shorten_name(author_name, 20)),
				author_hl = author_name,
				branch = utils.truncate(src .. " → " .. dst, 28),
				repo = string.format("%s %s", REPO_ICON, repo_label),
				repo_hl = repo_label,
				created = utils.relative_time(pr.created_on),
				updated = utils.relative_time(pr.updated_on),
				_item = { kind = "pr", id = pr.id, repo = group.repo, pr = pr },
			})
			table.insert(rows, {
				kind = "meta",
				pr_icon = "",
				repo_pr = src .. " → " .. dst,
				conversation = "",
				ci = "",
				ci_hl = "",
				review = "",
				review_hl = "",
				diff = "",
				diff_hl = nil,
				author = "",
				branch = "",
				repo = "",
				created = "",
				updated = "",
				separator = true,
				_item = { kind = "pr_meta", id = pr.id, repo = group.repo, pr = pr },
			})
		end
	end
	return rows
end

-- Plain layout

---@return table[]
local function plain_columns()
	return {
		{ key = "pr_icon", name = "", min_width = 1, can_grow = false, header_hl = "AtlasColumnHeader" },
		{ key = "name", name = "PR", min_width = 42, header_hl = "AtlasColumnHeader" },
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
			key = "branch",
			name = string.format("%s Branch", icons.pulls("branch")),
			max_width = 28,
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

---@param groups PullsGroup[]
---@return table[]
local function plain_rows(groups)
	local rows = {}
	for i, group in ipairs(groups or {}) do
		local repo_label = group.repo.name or ""
		if i > 1 then
			table.insert(rows, { kind = "spacer", pr_icon = "", name = "", conversation = "", ci = "", ci_hl = "", review = "", review_hl = "", diff = "", diff_hl = nil, author = "", branch = "", created = "", updated = "" })
		end
		table.insert(rows, {
			kind = "repo",
			pr_icon = REPO_ICON,
			name = repo_label,
			repo_full_name = repo_label,
			conversation = "",
			ci = "",
			ci_hl = "",
			review = "",
			review_hl = "",
			diff = "",
			diff_hl = nil,
			author = "",
			branch = "",
			created = "",
			updated = "",
			separator = true,
			_item = { kind = "repo", repo = group.repo },
		})
		for _, pr in ipairs(group.prs or {}) do
			local id_str = tostring(pr.id or "")
			local title = tostring(pr.title or "")
			local author_name = (pr.author and pr.author.name) and pr.author.name or ""
			local src = (pr.source and pr.source.branch) or ""
			local dst = (pr.destination and pr.destination.branch) or ""
			local icon = pr_icon_or_spinner(pr)
			local _, icon_hl = pr_icon_and_hl(pr)
			local ci, ci_h = ci_icon_and_hl(pr)
			local review, review_h = review_icon_and_hl(pr)
			local diff_result = diff_blocks.render({
				additions = tonumber(pr._raw and pr._raw.additions) or 0,
				deletions = tonumber(pr._raw and pr._raw.deletions) or 0,
				show_count = false,
			})
			table.insert(rows, {
				kind = "pr",
				pr_icon = icon,
				_pr_reloading = state.is_pr_reloading(pr.repo_full_name, pr.id),
				_pr_icon_str = icon,
				_pr_icon_hl = icon_hl,
				name = "#" .. id_str .. " " .. title,
				conversation = tostring(pr.comments_count or 0),
				ci = ci,
				ci_hl = ci_h,
				review = review,
				review_hl = review_h,
				diff = diff_result.text,
				diff_hl = diff_result.highlights,
				author = string.format("%s %s", icons.general("user"), utils.shorten_name(author_name, 20)),
				author_hl = author_name,
				branch = utils.truncate(src .. " → " .. dst, 28),
				created = utils.relative_time(pr.created_on),
				updated = utils.relative_time(pr.updated_on),
				_item = { kind = "pr", id = pr.id, repo = group.repo, pr = pr },
			})
		end
	end
	return rows
end

-- Render

---@param groups PullsGroup[]
---@param layout string
---@param opts { width: integer }
---@return PullsMainRenderResult
function M.render(groups, layout, opts)
	local lines = {}
	local spans = {}

	local tbl_lines, tbl_map, tbl_spans

	if layout == "plain" then
		tbl_lines, tbl_map, tbl_spans = table_tree.render({
			width = opts.width,
			margin = 1,
			columns = plain_columns(),
			rows = plain_rows(groups),
			cell_hl = cell_hl,
		})
	else
		tbl_lines, tbl_map, tbl_spans = table_tree.render({
			width = opts.width,
			margin = 1,
			columns = compact_columns(),
			rows = compact_rows(groups),
			cell_hl = cell_hl,
		})
	end

	add_pr_id_spans(tbl_lines, tbl_map, tbl_spans)

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
