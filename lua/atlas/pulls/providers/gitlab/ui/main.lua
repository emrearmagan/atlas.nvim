local M = {}

local helper = require("atlas.pulls.ui.main.helper")
local table_tree = require("atlas.ui.components.table_tree")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local state = require("atlas.pulls.state")

local PR_ICON, PR_ICON_HL = icons.pulls("pr")
local MERGED_PR_ICON, MERGED_PR_ICON_HL = icons.pulls("merged_pr")
local DECLINED_PR_ICON, DECLINED_PR_ICON_HL = icons.pulls("declined_pr")
local REPO_ICON = icons.pulls("repo")

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

local SUCCESS = { icons.pulls_status("successful") }
local FAILED = { icons.pulls_status("failed") }
local INPROGRESS = { icons.pulls_status("inprogress") }
local MUTED = { icons.pulls_status("inprogress") }
local STOPPED = { icons.pulls_status("stopped") }

MUTED[2] = "AtlasTextMuted"

local STATUS = {
	mergeable = SUCCESS,
	checking = INPROGRESS,
	unchecked = MUTED,
	ci_must_pass = FAILED,
	ci_still_running = INPROGRESS,
	discussions_not_resolved = FAILED,
	draft_status = STOPPED,
	not_approved = INPROGRESS,
	not_open = STOPPED,
	blocked_status = FAILED,
	merge_request_blocked = FAILED,
	conflict = FAILED,
	need_rebase = FAILED,
	preparing = INPROGRESS,
	requested_changes = FAILED,
	status_checks_must_pass = FAILED,
	security_policy_violations = FAILED,
	jira_association_missing = FAILED,
	external_status_checks = INPROGRESS,
	approvals_syncing = MUTED,
	commits_status = MUTED,
	policies_denied = FAILED,
}

---@param pr PullRequest
---@return string, string
local function ci_icon_and_hl(pr)
	local raw = pr._raw
	local s = tostring(raw.detailed_merge_status or raw.merge_status or ""):lower()
	if s == "" then
		return "", "AtlasTextMuted"
	end
	local entry = STATUS[s]
	if entry then
		return entry[1], entry[2]
	end
	return MUTED[1], MUTED[2]
end

---@param row table
---@param col table
---@param ctx table
---@return table[]|nil
local function cell_hl(row, col, ctx)
	if col.key == "ci" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = row.ci_hl or "AtlasTextMuted" } }
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
			local s, e = string.find(line, "!%d+")
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
		{ key = "repo_pr", name = "MR", min_width = 42, header_hl = "AtlasColumnHeader" },
		{
			key = "conversation",
			name = icons.general("comment"),
			min_width = 2,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{
			key = "ci",
			name = icons.pulls("pipeline") or icons.pulls_status("inprogress"),
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
			local is_reloading = state.is_pr_reloading(pr.repo_full_name, pr.id)
			local ci, ci_h = ci_icon_and_hl(pr)
			local icon, icon_hl = pr_icon_and_hl(pr)
			table.insert(rows, {
				kind = "pr",
				pr_icon = pr_icon_or_spinner(pr),
				_pr_reloading = is_reloading,
				_pr_icon_str = icon,
				_pr_icon_hl = icon_hl,
				repo_pr = "!" .. id_str .. " " .. title,
				conversation = tostring(pr.comments_count or 0),
				ci = ci,
				ci_hl = ci_h,
				author = string.format("%s %s", icons.general("user"), utils.shorten_name(author_name, 20)),
				author_hl = author_name,
				created = utils.relative_time(pr.created_on),
				updated = utils.relative_time(pr.updated_on),
				_item = { kind = "pr", id = pr.id, repo = group.repo, pr = pr },
			})
			table.insert(rows, {
				kind = "meta",
				pr_icon = "",
				repo_pr = repo_label,
				conversation = "",
				ci = "",
				ci_hl = "",
				author = "",
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
		{ key = "name", name = "MR", min_width = 42, header_hl = "AtlasColumnHeader" },
		{
			key = "conversation",
			name = icons.general("comment"),
			min_width = 2,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		},
		{
			key = "ci",
			name = icons.pulls("pipeline") or icons.pulls_status("inprogress"),
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
			table.insert(rows, {
				kind = "spacer",
				pr_icon = "",
				name = "",
				conversation = "",
				ci = "",
				ci_hl = "",
				author = "",
				created = "",
				updated = "",
			})
		end
		table.insert(rows, {
			kind = "repo",
			pr_icon = REPO_ICON,
			name = repo_label,
			repo_full_name = repo_label,
			conversation = "",
			ci = "",
			ci_hl = "",
			author = "",
			created = "",
			updated = "",
			separator = true,
			_item = { kind = "repo", repo = group.repo },
		})
		for _, pr in ipairs(group.prs or {}) do
			local id_str = tostring(pr.id or "")
			local title = tostring(pr.title or "")
			local author_name = (pr.author and pr.author.name) and pr.author.name or ""
			local icon = pr_icon_or_spinner(pr)
			local _, icon_hl = pr_icon_and_hl(pr)
			local ci, ci_h = ci_icon_and_hl(pr)
			table.insert(rows, {
				kind = "pr",
				pr_icon = icon,
				_pr_reloading = state.is_pr_reloading(pr.repo_full_name, pr.id),
				_pr_icon_str = icon,
				_pr_icon_hl = icon_hl,
				name = "!" .. id_str .. " " .. title,
				conversation = tostring(pr.comments_count or 0),
				ci = ci,
				ci_hl = ci_h,
				author = string.format("%s %s", icons.general("user"), utils.shorten_name(author_name, 20)),
				author_hl = author_name,
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
