---@class GitHubProviderPanel : PullsProviderPanel
local M = {}

local icons = require("atlas.ui.shared.icons")
local helper = require("atlas.pulls.ui.main.helper")

local MAX_HASH_LEN = 12

---@param hex string
---@return string
local function label_hl(hex)
	local name = string.format("AtlasGHLabel_%s", hex)
	vim.api.nvim_set_hl(0, name, { fg = "#1e1e2e", bg = "#" .. hex, bold = true })
	return name
end

local state = {
	header_extras = nil, ---@type { assignees: table|nil, labels: table|nil }|nil
	header_loading = false,
}

local function reset_state()
	state.header_extras = nil
	state.header_loading = false
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

---@param builds PullsBuild[]
---@return string
local function aggregate_build_status(builds)
	local has_success = false
	local has_stopped = false
	for _, b in ipairs(builds) do
		local s = tostring(b.state or ""):upper()
		if s == "FAILED" then
			return "failed"
		end
		if s == "INPROGRESS" then
			return "inprogress"
		end
		if s == "STOPPED" then
			has_stopped = true
		elseif s == "SUCCESSFUL" then
			has_success = true
		end
	end
	if has_success then
		return "successful"
	end
	if has_stopped then
		return "stopped"
	end
	return "unknown"
end

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

---@param pr PullRequest
---@return PullsPanelHeaderRow[]
function M.header_rows(pr) ---@diagnostic disable-line: unused-local
	local spinner = require("atlas.ui.components.spinner")

	if state.header_loading and state.header_extras == nil then
		return {
			{
				k1 = "Assignees:",
				v1 = spinner.with_text("Loading..."),
				v1_hl = "AtlasTextMuted",
				k2 = "",
				v2 = "",
				v2_hl = "AtlasTextMuted",
			},
		}
	end

	local extras = state.header_extras or {}
	local assignees = type(extras.assignees) == "table" and extras.assignees or {}
	local nodes = type(assignees.nodes) == "table" and assignees.nodes or {}

	local logins = {}
	for _, node in ipairs(nodes) do
		local login = type(node) == "table" and tostring(node.login or "") or ""
		if login ~= "" then
			table.insert(logins, login)
		end
	end

	local v1, v1_hl
	if #logins == 0 then
		v1 = "Unassigned"
		v1_hl = "AtlasTextMuted"
	else
		local parts = {}
		for _, login in ipairs(logins) do
			table.insert(parts, "@" .. login)
		end
		v1 = table.concat(parts, ", ")

		local spans = {}
		local cursor = 0
		for i, login in ipairs(logins) do
			local token = "@" .. login
			table.insert(spans, {
				start_col = cursor,
				end_col = cursor + #token,
				hl_group = helper.author_hl(login),
			})
			cursor = cursor + #token
			if i < #logins then
				local sep = ", "
				table.insert(spans, {
					start_col = cursor,
					end_col = cursor + #sep,
					hl_group = "AtlasTextMuted",
				})
				cursor = cursor + #sep
			end
		end
		v1_hl = spans
	end

	return {
		{
			k1 = "Assignees:",
			v1 = v1,
			v1_hl = v1_hl,
			k2 = "",
			v2 = "",
			v2_hl = "AtlasTextMuted",
		},
	}
end

---@param pr PullRequest
---@return PullsPanelChip[]
function M.chips(pr)
	local chips = {}

	local hash = tostring(pr.source and pr.source.commit_hash or "")
	if hash ~= "" then
		if #hash > MAX_HASH_LEN then
			hash = hash:sub(1, MAX_HASH_LEN)
		end
		table.insert(chips, { label = hash, hl = "AtlasTabInactive" })
	end

	if state.header_loading and state.header_extras == nil then
		local spinner = require("atlas.ui.components.spinner")
		table.insert(chips, { label = spinner.with_text("Loading labels"), hl = "AtlasTextMuted" })
	else
		local extras = state.header_extras or {}
		local labels = type(extras.labels) == "table" and extras.labels or {}
		local label_nodes = type(labels.nodes) == "table" and labels.nodes or {}
		for _, lbl in ipairs(label_nodes) do
			local name = tostring(lbl.name or "")
			if name ~= "" then
				local color = tostring(lbl.color or "")
				local hl = color ~= "" and label_hl(color) or "AtlasTabInactive"
				table.insert(chips, { label = name, hl = hl })
			end
		end
	end

	local BUILD_HL = {
		successful = "AtlasTextPositive",
		failed = "AtlasLogError",
		inprogress = "AtlasTextWarning",
		stopped = "AtlasTextMuted",
	}

	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	local spinner = require("atlas.ui.components.spinner")
	if overview_state.builds == "loading" then
		table.insert(chips, { label = spinner.with_text("Loading checks"), hl = "AtlasTextMuted" })
	elseif type(overview_state.builds) == "table" and #overview_state.builds > 0 then
		local builds = overview_state.builds --[[@as PullsBuild[] ]]
		local status = aggregate_build_status(builds)
		if status ~= "unknown" then
			local icon = icons.pulls_status(status)
			local label = status:sub(1, 1):upper() .. status:sub(2)
			table.insert(chips, {
				label = string.format("%s %s", icon, label),
				hl = BUILD_HL[status] or "AtlasTextMuted",
			})
		end
	end

	return chips
end

---@type { cancel: fun() }[]
local panel_in_flight = {}

local function cancel_panel_fetches()
	for _, handle in ipairs(panel_in_flight) do
		handle.cancel()
	end
	panel_in_flight = {}
end

---@param handle { cancel: fun() }|nil
local function track_panel(handle)
	if handle then
		table.insert(panel_in_flight, handle)
	end
end

---@param pr PullRequest
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.fetches(pr, refresh, opts)
	cancel_panel_fetches()
	reset_state()

	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	local pullrequests = require("atlas.pulls.providers.github.api.pullrequests")
	local checks = require("atlas.pulls.providers.github.api.checks")

	local owner = tostring(pr.workspace or "")
	local repo = tostring(pr.repo or "")
	local force = opts and opts.force_refresh == true

	if owner ~= "" and repo ~= "" and pr.id ~= nil then
		state.header_loading = true
		track_panel(pullrequests.get_pr(owner, repo, pr.id, function(fresh, err)
			state.header_loading = false
			if not err and type(fresh) == "table" then
				local raw = fresh._raw or fresh
				state.header_extras = {
					assignees = raw.assignees,
					labels = raw.labels,
				}
				pr.is_subscribed = fresh.is_subscribed
				pr._raw = fresh._raw
			end
			refresh()
		end, { force_load = force }))
	end

	overview_state.builds = "loading"
	track_panel(checks.get_builds(pr, { force_refresh = force }, function(builds, err)
		overview_state.builds = err and err or (builds or {})
		refresh()
	end))

	local files_state = require("atlas.pulls.ui.panel.pr.tabs.files.state")
	files_state.diffstat = "loading"
	track_panel(pullrequests.get_diffstat(pr, { force_refresh = force }, function(entries, err)
		files_state.diffstat = err and err or (entries or {})
		refresh()
	end))
end

---@param pr PullRequest
---@param active_tab string|nil
---@return boolean
function M.is_loading(pr, active_tab) ---@diagnostic disable-line: unused-local
	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	local conversation_state = require("atlas.pulls.ui.panel.pr.tabs.conversation.state")
	local comments_state = require("atlas.pulls.ui.panel.pr.tabs.review.state")
	local commits_state = require("atlas.pulls.ui.panel.pr.tabs.commits.state")
	local files_state = require("atlas.pulls.ui.panel.pr.tabs.files.state")
	if state.header_loading then
		return true
	end
	if active_tab == "overview" then
		return overview_state.any_loading()
	elseif active_tab == "conversation" then
		return conversation_state.any_loading()
	elseif active_tab == "review" then
		return comments_state.any_loading()
	elseif active_tab == "commits" then
		return commits_state.any_loading()
	elseif active_tab == "files" then
		return files_state.any_loading()
	end
	return false
end

--------------------------------------------------------------------------------
-- Tabs
--------------------------------------------------------------------------------

---@return PullsPanelTab[]
function M.tabs()
	return {
		{
			key = "overview",
			label = "Overview",
			icon = icons.general("overview"),
			mod = require("atlas.pulls.ui.panel.pr.tabs.overview"),
			keymaps = require("atlas.pulls.providers.github.ui.overview_keymaps"),
		},
		{
			key = "conversation",
			label = "Conversation",
			icon = icons.general("conversation"),
			mod = require("atlas.pulls.ui.panel.pr.tabs.conversation"),
		},
		{
			key = "review",
			label = "Review",
			icon = icons.pulls("review"),
			mod = require("atlas.pulls.ui.panel.pr.tabs.review"),
		},
		{
			key = "commits",
			label = "Commits",
			icon = icons.pulls("commit"),
			mod = require("atlas.pulls.ui.panel.pr.tabs.commits"),
		},
		{
			key = "files",
			label = "Changes",
			icon = icons.pulls("changes"),
			mod = require("atlas.pulls.ui.panel.pr.tabs.files"),
		},
	}
end


return M
