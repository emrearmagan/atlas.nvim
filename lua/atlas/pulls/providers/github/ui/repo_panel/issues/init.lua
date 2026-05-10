---@class GitHubRepoIssuesTab : PullsRepoPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local footer = require("atlas.ui.components.footer")
local state = require("atlas.pulls.providers.github.ui.repo_panel.issues.state")
local repo_panel_state = require("atlas.pulls.ui.panel.repo.state")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)
local COMMENT_ICON = icons.general("comment")

---@type { cancel: fun() }[]
local in_flight = {}

local function cancel_all()
	for _, handle in ipairs(in_flight) do
		handle.cancel()
	end
	in_flight = {}
end

---@param handle { cancel: fun() }|nil
local function track(handle)
	if handle then
		table.insert(in_flight, handle)
	end
end

local ISSUE_ICON = {
	open = { icon = icons.issues("issue"), hl = "AtlasPROpen" },
	closed = { icon = icons.pulls_status("successful"), hl = "AtlasTextPositive" },
}

local ISSUE_TYPE_COLORS = {
	RED = "d73a49",
	ORANGE = "e36209",
	YELLOW = "dbab09",
	GREEN = "28a745",
	TEAL = "0e8a16",
	BLUE = "0366d6",
	PURPLE = "6f42c1",
	PINK = "d876e3",
	GRAY = "6a737d",
}

---@param color_name string
---@return string
local function type_hl(color_name)
	local hex = ISSUE_TYPE_COLORS[(color_name or ""):upper()] or ISSUE_TYPE_COLORS.GRAY
	local name = string.format("AtlasGHIssueType_%s", hex)
	vim.api.nvim_set_hl(0, name, { fg = "#1e1e2e", bg = "#" .. hex, bold = true })
	return name
end

---@param width integer
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
local function render_filter_bar(width, lines, spans, line_map)
	local counts = state.counts
	local open_label = counts and string.format("Open (%d)", counts.open) or "Open"
	local closed_label = counts and string.format("Closed (%d)", counts.closed) or "Closed"
	local sep = "  "

	local line = PADDING .. open_label .. sep .. closed_label
	table.insert(lines, line)
	local lnum = #lines - 1

	local open_start = PADDING_X
	local open_end = open_start + #open_label
	local closed_start = open_end + #sep
	local closed_end = closed_start + #closed_label

	local open_hl = state.filter == "open" and "AtlasText" or "AtlasTextMuted"
	local closed_hl = state.filter == "closed" and "AtlasText" or "AtlasTextMuted"

	table.insert(spans, { line = lnum, start_col = open_start, end_col = open_end, hl_group = open_hl })
	table.insert(spans, { line = lnum, start_col = closed_start, end_col = closed_end, hl_group = closed_hl })

	local sep_width = math.max(8, width - (PADDING_X * 2))
	local sep_line = PADDING .. string.rep("─", sep_width)
	table.insert(lines, sep_line)
	table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #sep_line, hl_group = "AtlasBorder" })
end

---@param _repo PullsRepo
---@param width integer
---@return string[], table[], table<integer, table>
function M.render(_repo, width)
	local lines = {}
	local spans = {}
	local line_map = {}

	if state.issues == nil then
		if repo_panel_state.current_repo_details == "loading" then
			utils.push(lines, spans, spinner.with_text("Loading repository..."), "AtlasTextMuted", PADDING_X)
		end
		return lines, spans, line_map
	end

	if state.issues == "loading" then
		render_filter_bar(width, lines, spans, line_map)
		utils.push(lines, spans, spinner.with_text("Loading issues..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	if type(state.issues) == "string" then
		render_filter_bar(width, lines, spans, line_map)
		utils.push(lines, spans, state.issues, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	local issues = state.issues
	render_filter_bar(width, lines, spans, line_map)

	if #issues == 0 then
		local label = state.filter == "open" and "No open issues." or "No closed issues."
		utils.push(lines, spans, label, "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	for i, issue in ipairs(issues) do
		local s = tostring(issue.state or ""):lower()
		local icon_entry = ISSUE_ICON[s] or ISSUE_ICON.open
		local title = tostring(issue.title or "")
		local number = tostring(issue.number or "")
		local author = tostring(issue.author or "")
		local comments = tonumber(issue.comments) or 0
		local date_text = utils.relative_time_text(issue.created_at)

		local icon = icon_entry.icon
		local icon_prefix = PADDING .. icon .. " "
		local icon_prefix_w = vim.api.nvim_strwidth(icon_prefix)

		local right = ""
		local right_w = 0
		if comments > 0 then
			right = string.format("%s %d", COMMENT_ICON, comments)
			right_w = vim.api.nvim_strwidth(right) + 1
		end

		local title_max = math.max(1, width - icon_prefix_w - right_w - 1)
		local title_display = utils.truncate(title, title_max)
		local title_w = vim.api.nvim_strwidth(title_display)

		local line1
		if right ~= "" then
			local gap = math.max(1, width - icon_prefix_w - title_w - right_w - 1)
			line1 = icon_prefix .. title_display .. string.rep(" ", gap) .. right .. " "
		else
			line1 = icon_prefix .. title_display
		end

		table.insert(lines, line1)
		local lnum1 = #lines - 1
		line_map[#lines] = { kind = "issue", issue = issue, url = tostring(issue.url or "") }

		table.insert(spans, { line = lnum1, start_col = PADDING_X, end_col = PADDING_X + #icon, hl_group = icon_entry.hl })

		if right ~= "" then
			local right_start = #line1 - #right - 1
			table.insert(spans, { line = lnum1, start_col = right_start, end_col = right_start + #right, hl_group = "AtlasTextMuted" })
		end

		local indent = PADDING .. "  "
		local line2 = indent
		local lnum2_spans = {}

		local it = issue.issue_type
		if it and it.name ~= "" then
			local chip = " " .. it.name .. " "
			local chip_start = #line2
			line2 = line2 .. chip .. " "
			table.insert(lnum2_spans, { start_col = chip_start, end_col = chip_start + #chip, hl_group = type_hl(it.color) })
		end

		local meta_parts = { "#" .. number }
		if author ~= "" then
			table.insert(meta_parts, author .. " opened")
		end
		if date_text and date_text ~= "-" then
			table.insert(meta_parts, date_text)
		end
		local meta_text = table.concat(meta_parts, " · ")
		local meta_start = #line2
		line2 = line2 .. meta_text

		table.insert(lines, line2)
		local lnum2 = #lines - 1
		table.insert(lnum2_spans, { start_col = meta_start, end_col = #line2, hl_group = "AtlasTextMuted" })
		for _, sp in ipairs(lnum2_spans) do
			table.insert(spans, { line = lnum2, start_col = sp.start_col, end_col = sp.end_col, hl_group = sp.hl_group })
		end

		if i < #issues then
			local sep_width = math.max(8, width - (PADDING_X * 2))
			local sep_line = PADDING .. string.rep("─", sep_width)
			table.insert(lines, sep_line)
			table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #sep_line, hl_group = "AtlasBorder" })
		end
	end

	return lines, spans, line_map
end

local ISSUES_GQL = [[
query($owner: String!, $repo: String!, $states: [IssueState!]!) {
  repository(owner: $owner, name: $repo) {
    open: issues(states: OPEN) { totalCount }
    closed: issues(states: CLOSED) { totalCount }
    issues(first: 50, states: $states, orderBy: {field: CREATED_AT, direction: DESC}) {
      nodes {
        number title state url createdAt
        author { login }
        issueType { name color }
        labels(first: 10) { nodes { name color } }
        comments { totalCount }
      }
    }
  }
}
]]

---@param slug string
---@param refresh fun()
local function fetch_issues(slug, refresh)
	cancel_all()
	state.issues = "loading"
	state.last_slug = slug
	refresh()

	local cli = require("atlas.pulls.providers.github.api.cli")
	local parts = vim.split(slug, "/", { plain = true })
	local owner = parts[1] or ""
	local repo_name = parts[2] or ""

	if owner == "" or repo_name == "" then
		state.issues = "Missing repository info"
		refresh()
		return
	end

	local gql_state = state.filter == "open" and "OPEN" or "CLOSED"

	track(cli.gh({
		"api", "graphql",
		"-f", "query=" .. vim.trim(ISSUES_GQL),
		"-f", "owner=" .. owner,
		"-f", "repo=" .. repo_name,
		"-f", "states=" .. gql_state,
	}, function(result, err)
		if err then
			state.issues = tostring(err)
			footer.notify("error", string.format("Failed to load issues for %s", slug))
			refresh()
			return
		end

		local repo_data = type(result) == "table"
			and type(result.data) == "table"
			and type(result.data.repository) == "table"
			and result.data.repository or nil

		if not repo_data then
			state.issues = {}
			refresh()
			return
		end

		state.counts = {
			open = type(repo_data.open) == "table" and (tonumber(repo_data.open.totalCount) or 0) or 0,
			closed = type(repo_data.closed) == "table" and (tonumber(repo_data.closed.totalCount) or 0) or 0,
		}

		local nodes = type(repo_data.issues) == "table" and type(repo_data.issues.nodes) == "table"
			and repo_data.issues.nodes or {}

		local issues = {}
		for _, raw in ipairs(nodes) do
			local author_login = type(raw.author) == "table" and tostring(raw.author.login or "") or ""
			local comment_count = type(raw.comments) == "table" and (tonumber(raw.comments.totalCount) or 0) or 0
			local issue_type = nil
			if type(raw.issueType) == "table" then
				issue_type = {
					name = tostring(raw.issueType.name or ""),
					color = tostring(raw.issueType.color or "GRAY"),
				}
			end
			local label_nodes = type(raw.labels) == "table" and type(raw.labels.nodes) == "table"
				and raw.labels.nodes or {}

			table.insert(issues, {
				number = raw.number,
				title = tostring(raw.title or ""),
				state = tostring(raw.state or ""):lower(),
				author = author_login,
				created_at = tostring(raw.createdAt or ""),
				comments = comment_count,
				url = tostring(raw.url or ""),
				issue_type = issue_type,
				labels = label_nodes,
			})
		end

		state.issues = issues
		footer.notify("success", string.format("Issues loaded for %s", slug), 1200)
		refresh()
	end))
end

---@param _pr PullRequest|nil
---@param repo PullsRepo|nil
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(_pr, repo, refresh, opts)
	opts = opts or {}
	local detail = repo_panel_state.current_repo_details
	if repo == nil then
		state.reset()
		refresh()
		return
	end
	if detail == "loading" then
		state.issues = "loading"
		refresh()
		return
	end
	if type(detail) ~= "table" then
		state.reset()
		refresh()
		return
	end

	local slug = tostring(detail.full_name or "")
	if slug == "" then
		state.reset()
		refresh()
		return
	end

	local same_repo = state.last_slug == slug
	local should_fetch = opts.force_refresh == true
		or state.issues == nil
		or type(state.issues) == "string"
		or not same_repo
	if not should_fetch then
		refresh()
		return
	end

	footer.notify("loading", string.format("Loading issues for %s...", slug))
	fetch_issues(slug, refresh)
end

---@return boolean
function M.is_loading()
	return state.issues == "loading"
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	return entry.kind == "issue"
end

---@param _repo PullsRepo
---@param entry table
---@return boolean|nil
function M.on_enter(_repo, entry)
	if entry and entry.kind == "issue" and entry.url and entry.url ~= "" then
		vim.ui.open(entry.url)
		return true
	end
end

---@param refresh fun()
function M.toggle_filter(refresh)
	state.filter = state.filter == "open" and "closed" or "open"
	state.issues = nil

	local detail = repo_panel_state.current_repo_details
	if type(detail) ~= "table" then
		refresh()
		return
	end

	local slug = tostring(detail.full_name or "")
	if slug == "" then
		refresh()
		return
	end

	fetch_issues(slug, refresh)
end

function M.activate(buf, refresh)
	if buf == nil or refresh == nil then
		return
	end

	local help = require("atlas.ui.popups.help")
	help.register("Issues", {
		{
			key = "s",
			desc = "Toggle open/closed",
			opts = { nowait = true, silent = true },
			callback = function()
				M.toggle_filter(refresh)
			end,
		},
	}, { index = 212, buffer = buf })
end

function M.deactivate(buf)
	cancel_all()
	if buf then
		local help = require("atlas.ui.popups.help")
		help.remove("Issues", { { key = "s" } }, { buffer = buf })
	end
end

return M
