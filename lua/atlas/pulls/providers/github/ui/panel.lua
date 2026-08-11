---@class GitHubProviderPanel : PullsProviderPanel
local M = {}

local icons = require("atlas.ui.shared.icons")
local header = require("atlas.pulls.ui.panel.components.header")

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
}

local function reset_state()
	state.header_extras = nil
end

-- Panel

---@param _pr PullRequest
---@param loading boolean
---@return PullsPanelHeaderRow[]
function M.header_rows(_pr, loading)
	local spinner = require("atlas.ui.components.spinner")

	if loading and state.header_extras == nil then
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
---@param loading boolean
---@return PullsPanelChip[]
function M.chips(pr, loading)
	local chips = {}

	local hash = tostring(pr.source and pr.source.commit_hash or "")
	if hash ~= "" then
		if #hash > MAX_HASH_LEN then
			hash = hash:sub(1, MAX_HASH_LEN)
		end
		table.insert(chips, { label = hash, hl = "AtlasTabInactive" })
	end

	if loading and state.header_extras == nil then
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

	return chips
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil, pr_refreshed: boolean|nil }|nil
---@param on_done fun()
---@return { cancel: fun() }|nil
function M.fetch_header(pr, opts, on_done)
	reset_state()

	local pullrequests = require("atlas.pulls.providers.github.api.pullrequests")

	local owner = tostring(pr.workspace or "")
	local repo = tostring(pr.repo or "")
	local force = opts and opts.force_refresh == true

	if opts and opts.pr_refreshed then
		local raw = pr._raw or {}
		state.header_extras = {
			assignees = raw.assignees,
			labels = raw.labels,
		}
		on_done()
	elseif owner ~= "" and repo ~= "" and pr.id ~= nil then
		return pullrequests.get_pr(owner, repo, pr.id, function(fresh, err)
			if not err and type(fresh) == "table" then
				local raw = fresh._raw
				state.header_extras = {
					assignees = raw.assignees,
					labels = raw.labels,
				}
				pr.is_subscribed = fresh.is_subscribed
				pr._raw = fresh._raw
			end
			on_done()
		end, { force_load = force })
	else
		on_done()
	end
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
