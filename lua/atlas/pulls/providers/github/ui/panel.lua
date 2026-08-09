---@class GitHubProviderPanel : PullsProviderPanel
local M = {}

local icons = require("atlas.ui.shared.icons")
local header = require("atlas.pulls.ui.panel.components.header")
local providers = require("atlas.pulls.providers")

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

-- Helpers

-- Panel

---@param _pr PullRequest
---@return PullsPanelHeaderRow[]
function M.header_rows(_pr)
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

	return { header.assignee_row(logins) }
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

	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	local spinner = require("atlas.ui.components.spinner")
	if overview_state.pipelines == "loading" then
		table.insert(chips, { label = spinner.with_text("Loading pipelines"), hl = "AtlasTextMuted" })
	elseif type(overview_state.pipelines) == "table" and #overview_state.pipelines > 0 then
		local pipelines = overview_state.pipelines --[[@as PullsPipeline[] ]]
		local status = providers.aggregate_pipeline_state(pipelines):lower()
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
---@param opts { force_refresh: boolean|nil, pr_refreshed: boolean|nil }|nil
function M.fetches(pr, refresh, opts)
	cancel_panel_fetches()
	reset_state()

	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	local pullrequests = require("atlas.pulls.providers.github.api.pullrequests")
	local provider = require("atlas.pulls.state").provider
	local pipelines = provider and provider.capabilities.pipelines

	local owner = tostring(pr.workspace or "")
	local repo = tostring(pr.repo or "")
	local force = opts and opts.force_refresh == true

	if opts and opts.pr_refreshed then
		local raw = pr._raw or {}
		state.header_extras = {
			assignees = raw.assignees,
			labels = raw.labels,
		}
	elseif owner ~= "" and repo ~= "" and pr.id ~= nil then
		state.header_loading = true
		track_panel(pullrequests.get_pr(owner, repo, pr.id, function(fresh, err)
			state.header_loading = false
			if not err and type(fresh) == "table" then
				local raw = fresh._raw
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

	overview_state.pipelines = "loading"
	if pipelines then
		track_panel(pipelines.fetch(pr, { force_refresh = force }, function(items, err)
			overview_state.pipelines = err and err or (items or {})
			refresh()
		end))
	else
		overview_state.pipelines = {}
		refresh()
	end

	local panel_state = require("atlas.pulls.ui.panel.pr.state")
	panel_state.diffstat = "loading"
	track_panel(pullrequests.get_diffstat(pr, { force_refresh = force }, function(entries, err)
		panel_state.diffstat = err and err or (entries or {})
		refresh()
	end))
end

---@param _pr PullRequest
---@param active_tab string|nil
---@return boolean
function M.is_loading(_pr, active_tab)
	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	local conversation_state = require("atlas.pulls.ui.panel.pr.tabs.conversation.state")
	local comments_state = require("atlas.pulls.ui.panel.pr.tabs.review.state")
	local commits_state = require("atlas.pulls.ui.panel.pr.tabs.commits.state")
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
	end
	return false
end

-- Tabs

---@return PullsPanelTab[]
function M.tabs()
	local overview_icon, overview_hl = icons.general("overview")
	local conversation_icon, conversation_hl = icons.general("conversation")
	local review_icon, review_hl = icons.pulls("review")
	local commit_icon, commit_hl = icons.pulls("commit")
	return {
		{
			key = "overview",
			label = "Overview",
			icon = overview_icon,
			icon_hl = overview_hl,
			mod = require("atlas.pulls.ui.panel.pr.tabs.overview"),
			keymaps = require("atlas.pulls.providers.github.ui.overview_keymaps"),
		},
		{
			key = "conversation",
			label = "Conversation",
			icon = conversation_icon,
			icon_hl = conversation_hl,
			mod = require("atlas.pulls.ui.panel.pr.tabs.conversation"),
		},
		{
			key = "review",
			label = "Review",
			icon = review_icon,
			icon_hl = review_hl,
			mod = require("atlas.pulls.ui.panel.pr.tabs.review"),
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
