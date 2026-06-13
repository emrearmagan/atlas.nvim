---@class GiteaPullsProviderPanel : PullsProviderPanel
local M = {}

local icons = require("atlas.ui.shared.icons")

local state = {
	header_loading = false,
}

local function reset_state()
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
-- Panel interface
--------------------------------------------------------------------------------

---@param pr PullRequest
---@return PullsPanelHeaderRow[]
function M.header_rows(pr)
	local raw = type(pr._raw) == "table" and pr._raw or {}

	local state_hl = "AtlasTextMuted"
	local s = tostring(pr.state or ""):lower()
	if s == "open" then
		state_hl = "AtlasGiteaPROpen"
	elseif s == "merged" then
		state_hl = "AtlasGiteaPRMerged"
	elseif s == "declined" then
		state_hl = "AtlasGiteaPRDeclined"
	elseif s == "draft" then
		state_hl = "AtlasGiteaPRDraft"
	end

	local author = pr.author or {}
	local author_str = tostring(author.username or author.name or "")

	local src_branch = type(pr.source) == "table" and tostring(pr.source.branch or "") or ""
	local dst_branch = type(pr.destination) == "table" and tostring(pr.destination.branch or "") or ""
	local branch_str = src_branch ~= "" and (src_branch .. " → " .. dst_branch) or ""

	local additions = tonumber(raw.additions) or 0
	local deletions = tonumber(raw.deletions) or 0
	local changes_str = string.format("+%d / -%d", additions, deletions)

	return {
		{
			k1 = "State:",
			v1 = tostring(pr.state or "open"),
			v1_hl = state_hl,
			k2 = "Author:",
			v2 = author_str,
			v2_hl = "AtlasTextMuted",
		},
		{
			k1 = "Branch:",
			v1 = branch_str,
			v1_hl = "AtlasTextMuted",
			k2 = "Changes:",
			v2 = changes_str,
			v2_hl = "AtlasTextMuted",
		},
	}
end

---@param pr PullRequest
---@return PullsPanelChip[]
function M.chips(pr) ---@diagnostic disable-line: unused-local
	local chips = {}

	-- Show CI build status chip
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
			local icon = icons.pulls_status and icons.pulls_status(status) or ""
			local label = status:sub(1, 1):upper() .. status:sub(2)
			table.insert(chips, {
				label = icon ~= "" and string.format("%s %s", icon, label) or label,
				hl = BUILD_HL[status] or "AtlasTextMuted",
			})
		end
	end

	return chips
end

---@param pr PullRequest
---@param active_tab string|nil
---@return boolean
function M.is_loading(pr, active_tab) ---@diagnostic disable-line: unused-local
	if state.header_loading then
		return true
	end
	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	local conversation_state = require("atlas.pulls.ui.panel.pr.tabs.conversation.state")
	local commits_state = require("atlas.pulls.ui.panel.pr.tabs.commits.state")
	local files_state = require("atlas.pulls.ui.panel.pr.tabs.files.state")
	if active_tab == "overview" then
		return overview_state.any_loading()
	elseif active_tab == "conversation" then
		return conversation_state.any_loading()
	elseif active_tab == "commits" then
		return commits_state.any_loading()
	elseif active_tab == "files" then
		return files_state.any_loading()
	end
	return false
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
	local files_state = require("atlas.pulls.ui.panel.pr.tabs.files.state")
	local checks = require("atlas.pulls.providers.gitea.api.checks")
	local pullrequests = require("atlas.pulls.providers.gitea.api.pullrequests")

	local force = opts and opts.force_refresh == true

	-- Fetch CI builds
	overview_state.builds = "loading"
	track_panel(checks.get_builds(pr, { force_refresh = force }, function(builds, err)
		overview_state.builds = err and err or (builds or {})
		refresh()
	end))

	-- Fetch diffstat
	files_state.diffstat = "loading"
	track_panel(pullrequests.get_diffstat(pr, { force_refresh = force }, function(entries, err)
		files_state.diffstat = err and err or (entries or {})
		refresh()
	end))
end

--------------------------------------------------------------------------------
-- Tabs
--------------------------------------------------------------------------------

---@return PullsPanelTab[]
function M.tabs()
	return {
		{
			key = "conversation",
			label = "Conversation",
			icon = icons.general("conversation"),
			mod = require("atlas.pulls.ui.panel.pr.tabs.conversation"),
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
