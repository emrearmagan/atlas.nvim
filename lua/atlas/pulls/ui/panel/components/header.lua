local M = {}

local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.shared.highlights")
local table_tree = require("atlas.ui.components.table_tree")
local diff_blocks = require("atlas.ui.components.diff_blocks")
local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.pulls.ui.main.helper")

---@param spans table[]
---@param lines string[]
---@param line integer
---@param start_col integer
---@param end_col integer
---@param hl_group string
local function add_span(spans, lines, line, start_col, end_col, hl_group)
	local text = lines[line + 1] or ""
	local max_col = #text
	local s = math.max(0, math.min(start_col, max_col))
	local e = math.max(s, math.min(end_col, max_col))
	if e <= s then
		return
	end
	table.insert(spans, {
		line = line,
		start_col = s,
		end_col = e,
		hl_group = hl_group,
	})
end

---@param pr PullRequest
---@param width integer
---@param extra_rows PullsPanelHeaderRow[]|nil
---@return string[], table[]
function M.render(pr, width, extra_rows)
	local author_name = (pr.author and pr.author.name) or "Unknown"
	local created_text = utils.relative_time_text(pr.created_on)
	local repo_name = tostring(pr.repo_full_name or "")
	local src = tostring((pr.source or {}).branch or "?")
	local dst = tostring((pr.destination or {}).branch or "?")

	local id_text = string.format("#%s", tostring(pr.id or "?"))
	local title_text = tostring(pr.title or "")
	local title = string.format(" %s %s", id_text, title_text)

	local bell_icon, bell_hl
	if pr.is_subscribed ~= nil then
		bell_icon = pr.is_subscribed and icons.general("bell") or icons.general("bell_no")
		bell_hl = pr.is_subscribed and "AtlasLogInfo" or "AtlasTextMuted"
		local title_w = vim.api.nvim_strwidth(title)
		local bell_w = vim.api.nvim_strwidth(bell_icon)
		local pad = math.max(1, width - title_w - bell_w - 1)
		title = title .. string.rep(" ", pad) .. bell_icon
	end

	local author_icon = icons.general("user")
	local by_prefix = string.format(" %s by @", author_icon)
	local by_sep = " - "
	local byline = by_prefix .. author_name .. by_sep .. created_text

	local files_state = require("atlas.pulls.ui.panel.pr.tabs.files.state")
	local diff_result = nil
	if type(files_state.diffstat) == "table" and #files_state.diffstat > 0 then
		local total_add, total_del = 0, 0
		for _, entry in ipairs(files_state.diffstat) do
			total_add = total_add + (tonumber(entry.lines_added) or 0)
			total_del = total_del + (tonumber(entry.lines_removed) or 0)
		end
		diff_result = diff_blocks.render({ additions = total_add, deletions = total_del })
		if diff_result and diff_result.text ~= "" then
			local byline_w = vim.api.nvim_strwidth(byline)
			local diff_w = vim.api.nvim_strwidth(diff_result.text)
			local gap = math.max(2, width - byline_w - diff_w)
			byline = byline .. string.rep(" ", gap) .. diff_result.text
		end
	end

	local lines = {
		title,
		byline,
		"",
	}

	local updated_text = utils.relative_time_text(pr.updated_on)

	local rows = {
		{
			k1 = "Repo:",
			v1 = string.format("%s %s", icons.pulls("repo"), repo_name),
			v1_hl = highlights.dynamic_for(repo_name) or "AtlasTextMuted",
			k2 = "Updated:",
			v2 = updated_text,
			v2_hl = "AtlasTextMuted",
		},
		{
			k1 = "Branch:",
			v1 = string.format("%s %s → %s", icons.pulls("branch"), src, dst),
			v1_hl = "AtlasTextMuted",
			k2 = "",
			v2 = "",
			v2_hl = "AtlasTextMuted",
		},
	}

	for _, row in ipairs(extra_rows or {}) do
		table.insert(rows, row)
	end

	local tbl_lines, _, tbl_spans = table_tree.render({
		width = width,
		margin = 1,
		show_header = false,
		column_gap = 1,
		fill = true,
		columns = {
			{ key = "k1", name = "", can_grow = false },
			{ key = "v1", name = "", can_grow = true },
			{ key = "k2", name = "", can_grow = false },
			{ key = "v2", name = "", can_grow = true, grow_last = true },
		},
		rows = rows,
		cell_hl = function(row, col, ctx)
			if col.key == "k1" or col.key == "k2" then
				local label = col.key == "k1" and row.k1 or row.k2
				return { { start_col = 0, end_col = #label, hl_group = "AtlasTextMuted" } }
			end
			if col.key == "v1" then
				if type(row.v1_hl) == "table" then
					return row.v1_hl
				end
				return { { start_col = 0, end_col = #row.v1, hl_group = row.v1_hl } }
			end
			if col.key == "v2" then
				if type(row.v2_hl) == "table" then
					return row.v2_hl
				end
				return { { start_col = 0, end_col = #row.v2, hl_group = row.v2_hl } }
			end
			return nil
		end,
	})

	for _, l in ipairs(tbl_lines) do
		table.insert(lines, l)
	end
	table.insert(lines, "")

	-- Spans
	local spans = {
		{ line = 0, line_hl_group = "AtlasPanelHeaderBg" },
		{ line = 1, line_hl_group = "AtlasPanelHeaderBg" },
	}

	add_span(spans, lines, 0, 1, 1 + #id_text, "AtlasTextMuted")
	if bell_icon then
		add_span(spans, lines, 0, #title - #bell_icon, #title, bell_hl)
	end

	local author_start = #by_prefix - 1
	local author_end = author_start + #("@" .. author_name)
	add_span(spans, lines, 1, author_start, author_end, helper.author_hl(author_name))

	local ts_start = author_end + #by_sep
	local ts_end = ts_start + #created_text
	add_span(spans, lines, 1, ts_start, ts_end, "AtlasTextMuted")

	if diff_result and diff_result.text ~= "" then
		local diff_byte_start = #byline - #diff_result.text
		for _, hl in ipairs(diff_result.highlights) do
			add_span(spans, lines, 1, diff_byte_start + hl.start_col, diff_byte_start + hl.end_col, hl.hl_group)
		end
	end

	for _, span in ipairs(tbl_spans) do
		table.insert(spans, {
			line = span.line + 3,
			start_col = span.start_col,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end

	return lines, spans
end

---@param repo PullsRepo
---@return string
local function repo_full_name(repo)
	return tostring(repo.full_name or repo.name or repo.id or "Repository")
end

---@param repo PullsRepo
---@return string
local function repo_workspace(repo)
	local workspace = tostring(repo.workspace or "")
	if workspace ~= "" then
		return workspace
	end
	local full_name = repo_full_name(repo)
	return tostring(full_name:match("^([^/]+)/") or full_name)
end

---@param repo PullsRepo
---@param width integer
---@param extra_rows PullsPanelHeaderRow[]|nil
---@return string[], table[]
function M.render_repo(repo, width, extra_rows)
	local full_name = repo_full_name(repo)
	local workspace = repo_workspace(repo)
	local created_text = utils.relative_time_text(tostring(repo.created_on or ((repo._raw or {}).created_on) or ""))

	local title = string.format(" %s", full_name)
	local author_icon = icons.general("user")
	local by_prefix = string.format(" %s by @", author_icon)
	local by_sep = " - "
	local byline = by_prefix .. workspace .. by_sep .. created_text

	local lines = {
		title,
		byline,
		"",
	}

	local rows = {}

	local function icon_cell(icon, value, icon_hl)
		local text = string.format("%s %s", icon, tostring(value))
		local hl = {
			{ start_col = 0, end_col = #icon, hl_group = icon_hl },
			{ start_col = #icon, end_col = #text, hl_group = "AtlasTextMuted" },
		}
		return text, hl
	end

	local has_stars = tonumber(repo.stars) ~= nil
	local has_forks = tonumber(repo.forks) ~= nil
	local has_watchers = tonumber(repo.watchers) ~= nil

	if has_stars or has_forks then
		local v1, v1_hl
		if has_stars then
			v1, v1_hl = icon_cell(icons.general("star"), repo.stars, "AtlasTextWarning")
		else
			v1, v1_hl = "-", "AtlasTextMuted"
		end
		local v2, v2_hl
		if has_forks then
			v2, v2_hl = icon_cell(icons.pulls("fork"), repo.forks, "AtlasLogInfo")
		else
			v2, v2_hl = "-", "AtlasTextMuted"
		end
		table.insert(rows, {
			k1 = "Stars:",
			v1 = v1,
			v1_hl = v1_hl,
			k2 = "Forks:",
			v2 = v2,
			v2_hl = v2_hl,
		})
	end
	if has_watchers then
		local v1, v1_hl = icon_cell(icons.general("watching"), repo.watchers, "AtlasTextPositive")
		table.insert(rows, {
			k1 = "Watchers:",
			v1 = v1,
			v1_hl = v1_hl,
			k2 = "",
			v2 = "",
			v2_hl = "AtlasTextMuted",
		})
	end

	for _, row in ipairs(extra_rows or {}) do
		table.insert(rows, row)
	end

	if #rows > 0 then
		local tbl_lines, _, tbl_spans = table_tree.render({
			width = width,
			margin = 1,
			show_header = false,
			column_gap = 1,
			fill = true,
			columns = {
				{ key = "k1", name = "", can_grow = false },
				{ key = "v1", name = "", can_grow = true },
				{ key = "k2", name = "", can_grow = false },
				{ key = "v2", name = "", can_grow = true, grow_last = true },
			},
			rows = rows,
			cell_hl = function(row, col)
				if col.key == "k1" or col.key == "k2" then
					local label = col.key == "k1" and row.k1 or row.k2
					return { { start_col = 0, end_col = #label, hl_group = "AtlasTextMuted" } }
				end
				if col.key == "v1" then
					if type(row.v1_hl) == "table" then
						return row.v1_hl
					end
					return { { start_col = 0, end_col = #row.v1, hl_group = row.v1_hl } }
				end
				if col.key == "v2" then
					if type(row.v2_hl) == "table" then
						return row.v2_hl
					end
					return { { start_col = 0, end_col = #row.v2, hl_group = row.v2_hl } }
				end
				return nil
			end,
		})

		for _, l in ipairs(tbl_lines) do
			table.insert(lines, l)
		end
		table.insert(lines, "")

		local spans = {
			{ line = 0, line_hl_group = "AtlasPanelHeaderBg" },
			{ line = 1, line_hl_group = "AtlasPanelHeaderBg" },
		}

		add_span(spans, lines, 0, 1, 1 + #full_name, highlights.dynamic_for(full_name) or "AtlasTextMuted")

		local owner_start = #by_prefix - 1
		local owner_end = owner_start + #("@" .. workspace)
		add_span(spans, lines, 1, owner_start, owner_end, helper.author_hl(workspace))

		local ts_start = owner_end + #by_sep
		local ts_end = ts_start + #created_text
		add_span(spans, lines, 1, ts_start, ts_end, "AtlasTextMuted")

		for _, span in ipairs(tbl_spans) do
			table.insert(spans, {
				line = span.line + 3,
				start_col = span.start_col,
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end

		return lines, spans
	end

	local spans = {
		{ line = 0, line_hl_group = "AtlasPanelHeaderBg" },
		{ line = 1, line_hl_group = "AtlasPanelHeaderBg" },
	}
	add_span(spans, lines, 0, 1, 1 + #full_name, highlights.dynamic_for(full_name) or "AtlasTextMuted")
	local owner_start = #by_prefix - 1
	local owner_end = owner_start + #("@" .. workspace)
	add_span(spans, lines, 1, owner_start, owner_end, helper.author_hl(workspace))
	local ts_start = owner_end + #by_sep
	local ts_end = ts_start + #created_text
	add_span(spans, lines, 1, ts_start, ts_end, "AtlasTextMuted")
	return lines, spans
end

return M
