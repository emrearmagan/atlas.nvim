---@class GitHubRepoIssuesTab : PullsRepoPanelTabModule
local M = {}

local statusline = require("atlas.ui.statusline")
local state = require("atlas.pulls.providers.github.ui.repo_panel.issues.state")
local repo_panel_state = require("atlas.pulls.ui.panel.repo.state")
local issue_renderer = require("atlas.pulls.ui.panel.repo.tabs.issues.renderer")

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

---@param _repo PullsRepo
---@param width integer
---@return string[], table[], table<integer, table>
function M.render(_repo, width)
	return issue_renderer.render(state, width, repo_panel_state.current_repo_details == "loading", type_hl)
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

	local cli = require("atlas.providers.github.client").pulls
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
		"api",
		"graphql",
		"-f",
		"query=" .. vim.trim(ISSUES_GQL),
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. repo_name,
		"-f",
		"states=" .. gql_state,
	}, function(result, err)
		if err then
			state.issues = tostring(err)
			statusline.notify("error", string.format("Failed to load issues for %s", slug))
			refresh()
			return
		end

		local repo_data = type(result) == "table"
				and type(result.data) == "table"
				and type(result.data.repository) == "table"
				and result.data.repository
			or nil

		if not repo_data then
			state.issues = {}
			refresh()
			return
		end

		state.counts = {
			open = type(repo_data.open) == "table" and (tonumber(repo_data.open.totalCount) or 0) or 0,
			closed = type(repo_data.closed) == "table" and (tonumber(repo_data.closed.totalCount) or 0) or 0,
		}

		local nodes = type(repo_data.issues) == "table"
				and type(repo_data.issues.nodes) == "table"
				and repo_data.issues.nodes
			or {}

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
			local label_nodes = type(raw.labels) == "table" and type(raw.labels.nodes) == "table" and raw.labels.nodes
				or {}

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
		statusline.notify("success", string.format("Issues loaded for %s", slug), 1200)
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

	statusline.notify("loading", string.format("Loading issues for %s...", slug))
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
