---@class PullsRepoIssuesTab : PullsRepoPanelTabModule
local M = {}

local notify = require("atlas.core.notify")
local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local pulls_state = require("atlas.pulls.state")
local repo_panel_state = require("atlas.pulls.ui.panel.repo.state")
local renderer = require("atlas.pulls.ui.panel.repo.tabs.issues.renderer")
local state = require("atlas.pulls.ui.panel.repo.tabs.issues.state")

---@type { cancel: fun() }|nil
local request = nil

local function stop_request()
	if request ~= nil then
		request.cancel()
		request = nil
	end
end

local function reset()
	stop_request()
	state.reset()
end

---@param repo PullsRepoDetails
---@return string
local function repo_key(repo)
	return pulls_state.provider.id .. ":" .. tostring(repo.full_name or "")
end

---@param color string
---@return string
local function issue_type_hl(color)
	local hex = tostring(color or ""):gsub("^#", "")
	if hex == "" then
		hex = "6a737d"
	end
	local name = "AtlasRepoIssueType_" .. hex
	vim.api.nvim_set_hl(0, name, { fg = "#1e1e2e", bg = "#" .. hex, bold = true })
	return name
end

---@param _repo PullsRepo
---@param width integer
---@return string[], table[], table<integer, table>
function M.render(_repo, width)
	return renderer.render(state, width, repo_panel_state.current_repo_details == "loading", issue_type_hl)
end

---@param details PullsRepoDetails
---@param refresh fun()
---@param force_load boolean
local function fetch_issues(details, refresh, force_load)
	stop_request()
	local key = repo_key(details)
	if state.repo_key ~= key then
		state.counts = nil
	end
	local label = tostring(details.full_name or "")
	state.repo_key = key
	state.issues = "loading"
	notify.loading(string.format("Loading issues for %s...", label))
	refresh()

	local repository = pulls_state.provider.capabilities.repository
	local run = assert(repository.fetch_issues)
	request = run(details, state.filter, { force_load = force_load }, function(result, err)
		request = nil
		local current = repo_panel_state.current_repo_details
		if type(current) ~= "table" or repo_key(current) ~= key then
			return
		end
		if err then
			state.issues = tostring(err)
			notify.error(string.format("Failed to load issues for %s", label))
		else
			state.issues = result and result.entries or {}
			state.counts = result and result.counts or nil
			notify.success(string.format("Issues loaded for %s", label), { timeout = 1200 })
		end
		refresh()
	end)
end

---@param repo PullsRepo|nil
---@param refresh fun()
---@param opts PullsFetchOpts|nil
function M.on_select(repo, refresh, opts)
	opts = opts or {}
	local details = repo_panel_state.current_repo_details
	if repo == nil then
		reset()
		refresh()
		return
	end
	if details == "loading" then
		state.issues = "loading"
		refresh()
		return
	end
	if type(details) ~= "table" then
		reset()
		refresh()
		return
	end

	local key = repo_key(details)
	local should_fetch = opts.force_refresh == true
		or state.issues == nil
		or type(state.issues) == "string"
		or state.repo_key ~= key
	if not should_fetch then
		refresh()
		return
	end

	fetch_issues(details, refresh, opts.force_load == true or opts.force_refresh == true)
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
	if entry.kind == "issue" and entry.url and entry.url ~= "" then
		vim.ui.open(entry.url)
		return true
	end
end

---@param refresh fun()
function M.toggle_filter(refresh)
	state.filter = state.filter == "open" and "closed" or "open"
	state.issues = nil
	M.on_select(repo_panel_state.current_repo, refresh, { force_refresh = true })
end

---@param buf integer
---@param refresh fun()
function M.activate(buf, refresh)
	local keys = resolver.resolve("pulls.toggle_repo_issue_state")
	local items = {}
	if keys then
		table.insert(items, {
			key = #keys == 1 and keys[1] or keys,
			desc = "Toggle open/closed",
			opts = { nowait = true, silent = true },
			callback = function()
				M.toggle_filter(refresh)
			end,
		})
	end
	help.register("Issues", items, { index = 212, buffer = buf })
end

---@param buf integer|nil
function M.deactivate(buf)
	stop_request()
	if buf then
		local keys = resolver.resolve("pulls.toggle_repo_issue_state")
		local items = {}
		if keys then
			table.insert(items, { key = #keys == 1 and keys[1] or keys })
		end
		help.remove("Issues", items, { buffer = buf })
	end
end

return M
