---@class GitHubProviderPanel : PullsProviderPanel
local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local box = require("atlas.ui.components.box")
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
	merge_checks_loading = false,
	mergeable = nil, ---@type string|nil  "MERGEABLE"|"CONFLICTING"|"UNKNOWN"
	merge_state = nil, ---@type string|nil "CLEAN"|"DIRTY"|"BLOCKED"|"BEHIND"|"UNSTABLE"|"HAS_HOOKS"|"DRAFT"|"UNKNOWN"
	review_decision = nil, ---@type string|nil "APPROVED"|"CHANGES_REQUESTED"|"REVIEW_REQUIRED"|""
}

local function reset_state()
	state.header_extras = nil
	state.header_loading = false
	state.merge_checks_loading = false
	state.mergeable = nil
	state.merge_state = nil
	state.review_decision = nil
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
	if has_stopped then
		return "stopped"
	end
	if has_success then
		return "successful"
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
function M.fetches(pr, refresh)
	cancel_panel_fetches()
	reset_state()

	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	local pullrequests = require("atlas.pulls.providers.github.api.pullrequests")

	local owner = tostring(pr.workspace or "")
	local repo = tostring(pr.repo or "")

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
			end
			refresh()
		end))
	end

	overview_state.builds = "loading"
	track_panel(pullrequests.get_builds(pr, function(builds, err)
		overview_state.builds = err and err or (builds or {})
		refresh()
	end))

	state.merge_checks_loading = true
	track_panel(pullrequests.get_merge_checks(pr, function(result, _)
		state.merge_checks_loading = false
		if result then
			state.mergeable = result.mergeable
			state.merge_state = result.merge_state
			state.review_decision = result.review_decision
		end
		refresh()
	end))

	local files_state = require("atlas.pulls.ui.panel.pr.tabs.files.state")
	files_state.diffstat = "loading"
	track_panel(pullrequests.get_diffstat(pr, nil, function(entries, err)
		files_state.diffstat = err and err or (entries or {})
		refresh()
	end))
end

---@param pr PullRequest
---@param active_tab string|nil
---@return boolean
function M.is_loading(pr, active_tab) ---@diagnostic disable-line: unused-local
	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	local activity_state = require("atlas.pulls.ui.panel.pr.tabs.activity.state")
	local conversation_state = require("atlas.pulls.providers.github.ui.conversation.state")
	local commits_state = require("atlas.pulls.ui.panel.pr.tabs.commits.state")
	local files_state = require("atlas.pulls.ui.panel.pr.tabs.files.state")
	if state.header_loading then
		return true
	end
	if active_tab == "overview" then
		return overview_state.any_loading() or state.merge_checks_loading
	elseif active_tab == "activity" then
		return activity_state.any_loading()
	elseif active_tab == "conversation" then
		return conversation_state.any_loading()
	elseif active_tab == "commits" then
		return commits_state.any_loading()
	elseif active_tab == "files" then
		return files_state.any_loading()
	end
	return false
end

--------------------------------------------------------------------------------
-- Merge checks
--------------------------------------------------------------------------------

local PADDING_X = 1

local BUILD_STATE_ICON = {
	SUCCESSFUL = { icons.pulls_status("successful"), "AtlasTextPositive" },
	SUCCESS = { icons.pulls_status("successful"), "AtlasTextPositive" },
	FAILED = { icons.pulls_status("failed"), "AtlasLogError" },
	FAILURE = { icons.pulls_status("failed"), "AtlasLogError" },
	INPROGRESS = { icons.pulls_status("inprogress"), "AtlasTextWarning" },
	STOPPED = { icons.pulls_status("inprogress"), "AtlasTextMuted" },
}

---@param icon string
---@param icon_hl string
---@param label string
---@param details string[]|nil
---@return BoxContentGroup
local function render_check_group(icon, icon_hl, label, details, detail_spans, detail_lmap)
	local lines = {}
	local spans = {}
	local lmap = {}
	local line_text = string.format("%s %s", icon, label)
	table.insert(lines, line_text)
	table.insert(spans, {
		line = 0,
		start_col = 0,
		end_col = #icon,
		hl_group = icon_hl,
	})
	for di, detail in ipairs(details or {}) do
		local indent = "  "
		table.insert(lines, indent .. detail)
		local lnum = #lines - 1
		local ds = detail_spans and detail_spans[di] or nil
		if ds then
			table.insert(spans, { line = lnum, start_col = #indent, end_col = #indent + ds.icon_len, hl_group = ds.hl })
			table.insert(spans, {
				line = lnum,
				start_col = #indent + ds.icon_len,
				end_col = #lines[#lines],
				hl_group = "AtlasTextMuted",
			})
		else
			table.insert(spans, { line = lnum, start_col = 0, end_col = #lines[#lines], hl_group = "AtlasTextMuted" })
		end
		if detail_lmap and detail_lmap[di] then
			lmap[lnum] = detail_lmap[di]
		end
	end
	return { lines = lines, spans = spans, line_map = lmap }
end

---@class MergeCheckItem
---@field key string
---@field render fun(checks: table, builds: PullsBuild[]|string|nil, spinner: table): string|nil, string|nil, string|nil, string[]|nil, table[]|nil, table<integer, table>|nil

---@type MergeCheckItem[]
local MERGE_CHECK_ITEMS = {
	{
		key = "review",
		render = function(checks, _, spinner)
			local rd = checks.review_decision or ""
			if checks.loading then
				return icons.pulls_status("inprogress"),
					"AtlasTextMuted",
					"Reviews",
					{ spinner.with_text("Loading...") }
			elseif rd == "APPROVED" then
				return icons.pulls_status("successful"),
					"AtlasTextPositive",
					"Reviews",
					{ "All required reviewers have approved." }
			elseif rd == "CHANGES_REQUESTED" then
				return icons.pulls_status("failed"), "AtlasLogError", "Reviews", { "A reviewer has requested changes." }
			elseif rd == "REVIEW_REQUIRED" then
				return icons.pulls_status("inprogress"),
					"AtlasTextWarning",
					"Reviews",
					{ "At least one approving review is required." }
			else
				return icons.pulls_status("inprogress"), "AtlasTextMuted", "Reviews", { "No review required" }
			end
		end,
	},
	{
		key = "builds",
		render = function(_, builds, spinner)
			if builds == "loading" then
				return icons.pulls_status("inprogress"), "AtlasTextMuted", "Builds", { spinner.with_text("Loading...") }
			elseif type(builds) == "table" and #builds > 0 then
				local details = {}
				local detail_spans = {}
				local detail_lmap = {}
				for _, build in ipairs(builds) do
					local s = tostring(build.state or ""):upper()
					local p = BUILD_STATE_ICON[s] or BUILD_STATE_ICON.STOPPED
					local detail = string.format("%s %s", p[1], tostring(build.name or ""))
					table.insert(details, detail)
					table.insert(detail_spans, { icon_len = #p[1], hl = p[2] })
					detail_lmap[#details] = { kind = "build", build = build, url = tostring(build.url or "") }
				end
				local overall = aggregate_build_status(builds)
				local pair = BUILD_STATE_ICON[overall:upper()] or BUILD_STATE_ICON.STOPPED
				return pair[1], pair[2], "Builds", details, detail_spans, detail_lmap
			end
			return nil, nil, nil, nil
		end,
	},
	{
		key = "conflicts",
		render = function(checks, _, _)
			if checks.loading then
				return nil, nil, nil, nil
			end
			local m = checks.mergeable or ""
			if m == "MERGEABLE" then
				return icons.pulls_status("successful"),
					"AtlasTextPositive",
					"No conflicts with base branch",
					{ "Changes can be cleanly merged." }
			elseif m == "CONFLICTING" then
				return icons.pulls_status("failed"),
					"AtlasLogError",
					"This branch has conflicts that must be resolved",
					{ "Conflicting files must be resolved before merging." }
			end
			return nil, nil, nil, nil
		end,
	},
}

---@param pr PullRequest
---@param width integer
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>|nil
function M.overview_extra_sections(pr, width, lines, spans, line_map) ---@diagnostic disable-line: unused-local
	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	local spinner_mod = require("atlas.ui.components.spinner")
	local builds = overview_state.builds

	local has_merge_data = state.mergeable ~= nil or state.review_decision ~= nil
	if not has_merge_data and not state.merge_checks_loading and builds == nil then
		return
	end

	utils.push(lines, spans, "Merge Checks", "AtlasColumnHeader", PADDING_X)

	local checks = {
		loading = state.merge_checks_loading,
		mergeable = state.mergeable,
		merge_state = state.merge_state,
		review_decision = state.review_decision,
	}

	local groups = {}
	for _, item in ipairs(MERGE_CHECK_ITEMS) do
		local icon, icon_hl, label, details, dspans, dlmap = item.render(checks, builds, spinner_mod)
		if icon and icon_hl and label then
			table.insert(groups, render_check_group(icon, icon_hl, label, details, dspans, dlmap))
		end
	end

	if #groups > 0 then
		utils.append_block(
			lines,
			spans,
			box.render(groups, {
				width = width,
				padding_x = PADDING_X,
				line_map = line_map,
				line_offset = line_map and #lines or nil,
			})
		)
	end
	table.insert(lines, "")
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
			icon = icons.general("comment"),
			mod = require("atlas.pulls.providers.github.ui.conversation"),
		},
		{
			key = "activity",
			label = "Activity",
			icon = icons.pulls("activity"),
			mod = require("atlas.pulls.ui.panel.pr.tabs.activity"),
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
			icon = icons.pulls("files"),
			mod = require("atlas.pulls.ui.panel.pr.tabs.files"),
		},
	}
end

return M
