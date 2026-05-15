---@class BitbucketProviderPanel : PullsProviderPanel
local M = {}

local icons = require("atlas.ui.shared.icons")

local BUILD_HL = {
	successful = "AtlasTextPositive",
	failed = "AtlasLogError",
	inprogress = "AtlasTextWarning",
	stopped = "AtlasTextMuted",
}

local MAX_HASH_LEN = 12

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
	if has_stopped then
		return "stopped"
	end
	if has_success then
		return "successful"
	end
	return "unknown"
end

---@param pr PullRequest
---@return PullsPanelHeaderRow[]
function M.header_rows(pr)
	local raw = pr._raw or {}
	local rows = {}

	if raw.close_source_branch ~= nil then
		table.insert(rows, {
			k1 = "Close source:",
			v1 = raw.close_source_branch and icons.general("success") or icons.general("error"),
			v1_hl = raw.close_source_branch and "AtlasTextPositive" or "AtlasLogError",
			k2 = "",
			v2 = "",
			v2_hl = "AtlasTextMuted",
		})
	end

	return rows
end

---@param pr PullRequest
---@return PullsPanelChip[]
function M.chips(pr)
	local chips = {}
	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")

	local hash = tostring(pr.source and pr.source.commit_hash or "")
	if hash ~= "" then
		if #hash > MAX_HASH_LEN then
			hash = hash:sub(1, MAX_HASH_LEN)
		end
		table.insert(chips, { label = hash, hl = "AtlasTabInactive" })
	end

	local spinner = require("atlas.ui.components.spinner")
	if overview_state.builds == "loading" then
		table.insert(chips, { label = spinner.with_text("Loading builds"), hl = "AtlasTextMuted" })
	elseif type(overview_state.builds) == "table" and #overview_state.builds > 0 then
		local status = aggregate_build_status(overview_state.builds)
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
function M.fetches(pr, refresh)
	cancel_panel_fetches()

	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	overview_state.builds = "loading"

	local provider = require("atlas.pulls.state").provider
	if provider and type(provider.fetch_builds) == "function" then
		track_panel(provider.fetch_builds(pr, function(builds, err)
			overview_state.builds = err and err or (builds or {})
			refresh()
		end))
	end

	local files_state = require("atlas.pulls.ui.panel.pr.tabs.files.state")
	files_state.diffstat = "loading"
	if provider and type(provider.fetch_diffstat) == "function" then
		track_panel(provider.fetch_diffstat(pr, nil, function(entries, err)
			files_state.diffstat = err and err or (entries or {})
			refresh()
		end))
	end
end

---@param pr PullRequest
---@param active_tab string|nil
---@return boolean
function M.is_loading(pr, active_tab)
	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	local activity_state = require("atlas.pulls.ui.panel.pr.tabs.activity.state")
	local comments_state = require("atlas.pulls.ui.panel.pr.tabs.review.state")
	local commits_state = require("atlas.pulls.ui.panel.pr.tabs.commits.state")
	local files_state = require("atlas.pulls.ui.panel.pr.tabs.files.state")
	if active_tab == "overview" then
		return overview_state.any_loading()
	elseif active_tab == "activity" then
		return activity_state.any_loading()
	elseif active_tab == "review" then
		return comments_state.any_loading()
	elseif active_tab == "commits" then
		return commits_state.any_loading()
	elseif active_tab == "files" then
		return files_state.any_loading()
	end
	return false
end

---@return PullsPanelTab[]
function M.tabs()
	return {
		{
			key = "overview",
			label = "Overview",
			icon = icons.general("overview"),
			mod = require("atlas.pulls.ui.panel.pr.tabs.overview"),
		},
		{
			key = "activity",
			label = "Activity",
			icon = icons.pulls("activity"),
			mod = require("atlas.pulls.ui.panel.pr.tabs.activity"),
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
