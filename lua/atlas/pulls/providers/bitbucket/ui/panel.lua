---@class BitbucketProviderPanel : PullsProviderPanel
local M = {}

local icons = require("atlas.ui.shared.icons")

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
	local raw = pr._raw
	local rows = {}

	if raw.close_source_branch ~= nil then
		local state_icon, state_icon_hl
		if raw.close_source_branch then
			state_icon, state_icon_hl = icons.general("success")
		else
			state_icon, state_icon_hl = icons.general("error")
		end
		table.insert(rows, {
			k1 = "Close source:",
			v1 = state_icon,
			v1_hl = state_icon_hl,
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
			local icon, icon_hl = icons.pulls_status(status)
			local label = status:sub(1, 1):upper() .. status:sub(2)
			table.insert(chips, {
				label = string.format("%s %s", icon, label),
				hl = icon_hl,
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
	if provider and provider.fetch_builds then
		track_panel(provider.fetch_builds(pr, function(builds, err)
			overview_state.builds = err and err or (builds or {})
			refresh()
		end))
	end

	local panel_state = require("atlas.pulls.ui.panel.pr.state")
	panel_state.diffstat = "loading"
	if provider and provider.fetch_diffstat then
		track_panel(provider.fetch_diffstat(pr, nil, function(entries, err)
			panel_state.diffstat = err and err or (entries or {})
			refresh()
		end))
	end
end

---@param pr PullRequest
---@param active_tab string|nil
---@return boolean
function M.is_loading(_pr, active_tab)
	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	local activity_state = require("atlas.pulls.ui.panel.pr.tabs.activity.state")
	local comments_state = require("atlas.pulls.ui.panel.pr.tabs.review.state")
	local commits_state = require("atlas.pulls.ui.panel.pr.tabs.commits.state")
	if active_tab == "overview" then
		return overview_state.any_loading()
	elseif active_tab == "activity" then
		return activity_state.any_loading()
	elseif active_tab == "review" then
		return comments_state.any_loading()
	elseif active_tab == "commits" then
		return commits_state.any_loading()
	end
	return false
end

---@return PullsPanelTab[]
function M.tabs()
	local overview_icon, overview_hl = icons.general("overview")
	local activity_icon, activity_hl = icons.pulls("activity")
	local review_icon, review_hl = icons.pulls("review")
	local commit_icon, commit_hl = icons.pulls("commit")
	return {
		{
			key = "overview",
			label = "Overview",
			icon = overview_icon,
			icon_hl = overview_hl,
			mod = require("atlas.pulls.ui.panel.pr.tabs.overview"),
		},
		{
			key = "review",
			label = "Review",
			icon = review_icon,
			icon_hl = review_hl,
			mod = require("atlas.pulls.ui.panel.pr.tabs.review"),
		},
		{
			key = "activity",
			label = "Activity",
			icon = activity_icon,
			icon_hl = activity_hl,
			mod = require("atlas.pulls.ui.panel.pr.tabs.activity"),
		},
		{
			key = "commits",
			label = "Commits",
			icon = commit_icon,
			icon_hl = commit_hl,
			mod = require("atlas.pulls.ui.panel.pr.tabs.commits"),
		},
	}
end

return M
