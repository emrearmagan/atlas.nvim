---@class GitLabRepoIssuesTab : PullsRepoPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local footer = require("atlas.ui.components.footer")
local service = require("atlas.pulls.providers.gitlab.api.service")
local state = require("atlas.pulls.providers.gitlab.ui.repo_panel.issues.state")
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

---@param width integer
---@param lines string[]
---@param spans table[]
local function render_filter_bar(width, lines, spans)
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
		render_filter_bar(width, lines, spans)
		utils.push(lines, spans, spinner.with_text("Loading issues..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	if type(state.issues) == "string" then
		render_filter_bar(width, lines, spans)
		utils.push(lines, spans, state.issues, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	local issues = state.issues
	render_filter_bar(width, lines, spans)

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

		table.insert(
			spans,
			{ line = lnum1, start_col = PADDING_X, end_col = PADDING_X + #icon, hl_group = icon_entry.hl }
		)

		if right ~= "" then
			local right_start = #line1 - #right - 1
			table.insert(spans, {
				line = lnum1,
				start_col = right_start,
				end_col = right_start + #right,
				hl_group = "AtlasTextMuted",
			})
		end

		local indent = PADDING .. "  "
		local line2 = indent
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
		table.insert(spans, { line = lnum2, start_col = meta_start, end_col = #line2, hl_group = "AtlasTextMuted" })

		if i < #issues then
			local sep_width = math.max(8, width - (PADDING_X * 2))
			local sep_line = PADDING .. string.rep("─", sep_width)
			table.insert(lines, sep_line)
			table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #sep_line, hl_group = "AtlasBorder" })
		end
	end

	return lines, spans, line_map
end

---@param path string
---@param refresh fun()
local function fetch_issues(path, refresh)
	cancel_all()
	state.issues = "loading"
	state.last_path = path
	refresh()

	local api_state = state.filter == "open" and "opened" or "closed"
	local list_endpoint = string.format(
		"/projects/%s/issues?state=%s&per_page=50&order_by=created_at&sort=desc",
		service.url_encode(path),
		api_state
	)

	track(service.request("GET", list_endpoint, nil, function(result, err)
		if err then
			state.issues = tostring(err)
			footer.notify("error", string.format("Failed to load issues for %s", path))
			refresh()
			return
		end

		local issues = {}
		for _, raw in ipairs(type(result) == "table" and result or {}) do
			local author = type(raw.author) == "table" and tostring(raw.author.username or raw.author.name or "") or ""
			table.insert(issues, {
				number = raw.iid,
				title = tostring(raw.title or ""),
				state = tostring(raw.state or ""):lower() == "closed" and "closed" or "open",
				author = author,
				created_at = tostring(raw.created_at or ""),
				comments = tonumber(raw.user_notes_count) or 0,
				url = tostring(raw.web_url or ""),
			})
		end

		state.issues = issues
		footer.notify("success", string.format("Issues loaded for %s", path), 1200)
		refresh()
	end))

	local stats_endpoint = string.format("/projects/%s/issues_statistics", service.url_encode(path))
	track(service.request("GET", stats_endpoint, nil, function(result, _)
		local counts = type(result) == "table" and type(result.statistics) == "table" and result.statistics.counts
		if type(counts) == "table" then
			state.counts = {
				open = tonumber(counts.opened) or 0,
				closed = tonumber(counts.closed) or 0,
			}
			refresh()
		end
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

	local path = tostring(detail.full_name or "")
	if path == "" then
		state.reset()
		refresh()
		return
	end

	local same_path = state.last_path == path
	local should_fetch = opts.force_refresh == true
		or state.issues == nil
		or type(state.issues) == "string"
		or not same_path
	if not should_fetch then
		refresh()
		return
	end

	footer.notify("loading", string.format("Loading issues for %s...", path))
	fetch_issues(path, refresh)
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

	local path = tostring(detail.full_name or "")
	if path == "" then
		refresh()
		return
	end

	fetch_issues(path, refresh)
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
