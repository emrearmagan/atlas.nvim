local M = {}

local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.shared.highlights")
local spinner = require("atlas.ui.components.spinner")
local table_tree = require("atlas.ui.components.table_tree")
local utils = require("atlas.ui.shared.utils")
local presentation = require("atlas.pulls.ui.presentation")

---@param label string
---@return PullsDetailHeaderField
function M.loading_field(label)
	return { label = label, value = spinner.with_text("Loading..."), hl = "AtlasTextMuted" }
end

---@param logins string[]
---@return PullsDetailHeaderField
function M.assignee_field(logins)
	if #logins == 0 then
		return {
			label = "Assignees",
			value = "Unassigned",
			hl = "AtlasTextMuted",
		}
	end

	local parts = {}
	local spans = {}
	local cursor = 0
	for i, login in ipairs(logins) do
		local token = "@" .. login
		table.insert(parts, token)
		table.insert(spans, {
			start_col = cursor,
			end_col = cursor + #token,
			hl_group = presentation.author_hl(login),
		})
		cursor = cursor + #token
		if i < #logins then
			table.insert(spans, {
				start_col = cursor,
				end_col = cursor + 2,
				hl_group = "AtlasTextMuted",
			})
			cursor = cursor + 2
		end
	end

	return {
		label = "Assignees",
		value = table.concat(parts, ", "),
		hl = spans,
	}
end

---@param text string
---@param hl string|table[]|nil
---@return table[]|nil
local function value_hl_spans(text, hl)
	if type(hl) == "table" then
		return #hl > 0 and hl or nil
	end
	if type(hl) == "string" and hl ~= "" then
		return { { start_col = 0, end_col = #text, hl_group = hl } }
	end
end

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
---@param extra_fields PullsDetailHeaderField[]|nil
---@return string[], table[]
function M.render(pr, width, extra_fields)
	local author_name = presentation.user_handle(pr.author)
	local created_text = utils.relative_time_text(pr.created_on)
	local repo_name = pr.repo_full_name
	local src = tostring(pr.source.branch or "")
	local dst = tostring(pr.destination.branch or "")

	local id_text = string.format("#%s", pr.id)
	local title_text = pr.title
	local title_lines = utils.wrap_line(string.format("%s %s", id_text, title_text), math.max(1, width - 1))
	for index, line in ipairs(title_lines) do
		title_lines[index] = " " .. line
	end

	local author_icon, author_icon_hl = icons.general("user")
	local by_prefix = string.format(" %s by @", author_icon)
	local by_sep = " - "
	local byline = by_prefix .. author_name .. by_sep .. created_text

	local lines = vim.list_extend({}, title_lines)
	vim.list_extend(lines, { byline, "" })

	local updated_text = utils.relative_time_text(pr.updated_on)

	local fields = {
		{
			label = "Repo",
			value = string.format("%s %s", icons.pulls("repo"), repo_name),
			hl = highlights.dynamic_for(repo_name) or "AtlasTextMuted",
		},
		{
			label = "Updated",
			value = updated_text,
			hl = "AtlasTextMuted",
		},
	}

	for _, field in ipairs(extra_fields or {}) do
		table.insert(fields, field)
	end
	if src ~= "" and dst ~= "" then
		table.insert(fields, {
			label = "Branch",
			value = string.format("%s %s → %s", icons.pulls("branch"), src, dst),
			hl = "AtlasTextMuted",
		})
	end

	local rows = {}
	for index = 1, #fields, 2 do
		local left = fields[index]
		local right = fields[index + 1]
		table.insert(rows, {
			k1 = left.label .. ":",
			v1 = left.value,
			v1_hl = left.hl,
			k2 = right and (right.label .. ":") or "",
			v2 = right and right.value or "",
			v2_hl = right and right.hl or nil,
		})
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
		cell_hl = function(row, col, _ctx)
			if col.key == "k1" or col.key == "k2" then
				local label = col.key == "k1" and row.k1 or row.k2
				return { { start_col = 0, end_col = #label, hl_group = "AtlasTextMuted" } }
			end
			if col.key == "v1" then
				return value_hl_spans(row.v1, row.v1_hl)
			end
			if col.key == "v2" and row.v2 ~= "" then
				return value_hl_spans(row.v2, row.v2_hl)
			end
			return nil
		end,
	})

	for _, l in ipairs(tbl_lines) do
		table.insert(lines, l)
	end
	table.insert(lines, "")

	-- Spans
	local spans = {}
	for line = 0, #title_lines do
		table.insert(spans, { line = line, line_hl_group = "AtlasTabInactive" })
	end

	add_span(spans, lines, 0, 1, 1 + #id_text, "AtlasTextMuted")
	local author_line = #title_lines
	add_span(spans, lines, author_line, 1, 1 + #author_icon, author_icon_hl)

	local author_start = #by_prefix - 1
	local author_end = author_start + #("@" .. author_name)
	add_span(spans, lines, author_line, author_start, author_end, presentation.author_hl(author_name))

	local ts_start = author_end + #by_sep
	local ts_end = ts_start + #created_text
	add_span(spans, lines, author_line, ts_start, ts_end, "AtlasTextMuted")

	for _, span in ipairs(tbl_spans) do
		table.insert(spans, {
			line = span.line + #title_lines + 2,
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
---@return string[], table[]
function M.render_repo(repo, width)
	local full_name = repo_full_name(repo)
	local workspace = repo_workspace(repo)
	local created_text = utils.relative_time_text(tostring(repo.created_on or ""))

	local title = string.format(" %s", full_name)
	local author_icon, author_icon_hl = icons.general("user")
	local by_prefix = string.format(" %s by @", author_icon)
	local by_sep = " - "
	local byline = by_prefix .. workspace .. by_sep .. created_text

	local lines = {
		title,
		byline,
		"",
	}

	local rows = {}

	local has_stars = tonumber(repo.stars) ~= nil
	local has_forks = tonumber(repo.forks) ~= nil
	local has_watchers = tonumber(repo.watchers) ~= nil

	if has_stars or has_forks then
		local k1, k1_hl, v1
		if has_stars then
			k1, k1_hl = icons.general("star")
			v1 = string.format("Stars: %s", repo.stars)
		else
			k1, k1_hl, v1 = "", "AtlasTextMuted", "Stars: -"
		end
		local k2, k2_hl, v2
		if has_forks then
			k2, k2_hl = icons.pulls("fork")
			v2 = string.format("Forks: %s", repo.forks)
		else
			k2, k2_hl, v2 = "", "AtlasTextMuted", "Forks: -"
		end
		table.insert(rows, {
			k1 = k1,
			k1_hl = k1_hl,
			v1 = v1,
			v1_hl = "AtlasTextMuted",
			k2 = k2,
			k2_hl = k2_hl,
			v2 = v2,
			v2_hl = "AtlasTextMuted",
		})
	end
	if has_watchers then
		local watching_icon, watching_hl = icons.general("watching")
		table.insert(rows, {
			k1 = watching_icon,
			k1_hl = watching_hl,
			v1 = string.format("Watchers: %s", repo.watchers),
			v1_hl = "AtlasTextMuted",
			k2 = "",
			v2 = "",
			v2_hl = "AtlasTextMuted",
		})
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
					local hl = col.key == "k1" and row.k1_hl or row.k2_hl
					return { { start_col = 0, end_col = #label, hl_group = hl or "AtlasTextMuted" } }
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
			{ line = 0, line_hl_group = "AtlasTabInactive" },
			{ line = 1, line_hl_group = "AtlasTabInactive" },
		}

		add_span(spans, lines, 0, 1, 1 + #full_name, highlights.dynamic_for(full_name) or "AtlasTextMuted")
		add_span(spans, lines, 1, 1, 1 + #author_icon, author_icon_hl)

		local owner_start = #by_prefix - 1
		local owner_end = owner_start + #("@" .. workspace)
		add_span(spans, lines, 1, owner_start, owner_end, presentation.author_hl(workspace))

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
		{ line = 0, line_hl_group = "AtlasTabInactive" },
		{ line = 1, line_hl_group = "AtlasTabInactive" },
	}
	add_span(spans, lines, 0, 1, 1 + #full_name, highlights.dynamic_for(full_name) or "AtlasTextMuted")
	add_span(spans, lines, 1, 1, 1 + #author_icon, author_icon_hl)
	local owner_start = #by_prefix - 1
	local owner_end = owner_start + #("@" .. workspace)
	add_span(spans, lines, 1, owner_start, owner_end, presentation.author_hl(workspace))
	local ts_start = owner_end + #by_sep
	local ts_end = ts_start + #created_text
	add_span(spans, lines, 1, ts_start, ts_end, "AtlasTextMuted")
	return lines, spans
end

return M
