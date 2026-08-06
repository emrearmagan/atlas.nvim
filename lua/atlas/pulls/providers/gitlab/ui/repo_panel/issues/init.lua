---@class GitLabRepoIssuesTab : PullsRepoPanelTabModule
local M = {}

local statusline = require("atlas.ui.statusline")
local service = require("atlas.providers.gitlab.client").pulls
local state = require("atlas.pulls.providers.gitlab.ui.repo_panel.issues.state")
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

---@param _repo PullsRepo
---@param width integer
---@return string[], table[], table<integer, table>
function M.render(_repo, width)
	return issue_renderer.render(state, width, repo_panel_state.current_repo_details == "loading")
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
			statusline.notify("error", string.format("Failed to load issues for %s", path))
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
		statusline.notify("success", string.format("Issues loaded for %s", path), 1200)
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

	statusline.notify("loading", string.format("Loading issues for %s...", path))
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
